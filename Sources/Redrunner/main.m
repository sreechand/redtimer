#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import <unistd.h>

static const NSTimeInterval VTMaximumDuration = 60 * 60;
static NSString * const VTAppDisplayName = @"redrunner";
static NSString * const VTNotificationIdentifier = @"redrunner-expiration";
static NSString * const VTKeyConfiguredDuration = @"timer.configuredDuration";
static NSString * const VTKeyRemaining = @"timer.remaining";
static NSString * const VTKeyRunning = @"timer.isRunning";
static NSString * const VTKeyDeadline = @"timer.deadline";
static NSString * const VTKeyPinned = @"preferences.isPinned";
static NSString * const VTKeySilent = @"preferences.isSilent";
static NSString * const VTKeyHaptics = @"preferences.hapticsEnabled";
static NSString * const VTTimerModelDidChangeNotification = @"VTTimerModelDidChangeNotification";

static BOOL VTRelaunchAppBundleIfRawExecutableLaunch(const char *executablePath) {
    if (getppid() == 1 || getenv("REDRUNNER_ALLOW_RAW_LAUNCH")) {
        return NO;
    }

    NSString *path = executablePath ? [NSString stringWithUTF8String:executablePath] : NSProcessInfo.processInfo.arguments.firstObject;
    if (path.length == 0) {
        return NO;
    }

    if (!path.isAbsolutePath) {
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    }

    NSString *standardizedPath = path.stringByStandardizingPath;
    NSRange appRange = [standardizedPath rangeOfString:@".app/Contents/MacOS/" options:NSBackwardsSearch];
    if (appRange.location == NSNotFound) {
        return NO;
    }

    NSString *bundlePath = [standardizedPath substringToIndex:appRange.location + 4];
    if (![NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        return NO;
    }

    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[@"-n", bundlePath];
    [task launch];

    fprintf(stderr, "%s is a macOS app bundle. Reopening %s through LaunchServices.\n",
            VTAppDisplayName.UTF8String,
            bundlePath.UTF8String);
    return YES;
}

@class VTTimerModel;

@protocol VTTimerModelDelegate <NSObject>
- (void)timerModelDidChange:(VTTimerModel *)model;
@end

@interface VTTimerModel : NSObject
@property (nonatomic, weak) id<VTTimerModelDelegate> delegate;
@property (nonatomic, readonly) NSTimeInterval configuredDuration;
@property (nonatomic, readonly) NSTimeInterval remaining;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic) BOOL pinned;
@property (nonatomic) BOOL silent;
@property (nonatomic) BOOL hapticsEnabled;
- (NSString *)formattedRemaining;
- (NSString *)statusText;
- (CGFloat)visualFraction;
- (void)toggleStartPause;
- (void)start;
- (void)pause;
- (void)reset;
- (void)setDurationMinutes:(CGFloat)minutes;
- (void)setDurationFromPoint:(NSPoint)point inSize:(NSSize)size;
@end

@interface VTTimerModel ()
@property (nonatomic) NSTimeInterval configuredDuration;
@property (nonatomic) NSTimeInterval remaining;
@property (nonatomic, getter=isRunning) BOOL running;
@property (nonatomic, strong) NSDate *deadline;
@property (nonatomic, strong) NSTimer *displayTimer;
@property (nonatomic) BOOL didFireCompletion;
@end

@implementation VTTimerModel

- (instancetype)init {
    self = [super init];
    if (!self) { return nil; }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _configuredDuration = [defaults doubleForKey:VTKeyConfiguredDuration];
    _remaining = [defaults doubleForKey:VTKeyRemaining];
    _pinned = [defaults boolForKey:VTKeyPinned];
    _silent = [defaults boolForKey:VTKeySilent];
    _hapticsEnabled = [defaults objectForKey:VTKeyHaptics] ? [defaults boolForKey:VTKeyHaptics] : YES;

    NSDate *savedDeadline = [defaults objectForKey:VTKeyDeadline];
    if (savedDeadline && [defaults boolForKey:VTKeyRunning]) {
        _deadline = savedDeadline;
        _remaining = MAX(0, savedDeadline.timeIntervalSinceNow);
        _running = _remaining > 0;
    }

    if (_remaining <= 0) {
        _configuredDuration = 0;
        _remaining = 0;
    }

    [self persistTimerState];
    [self startDisplayTimer];
    return self;
}

- (void)dealloc {
    [_displayTimer invalidate];
}

- (void)setPinned:(BOOL)pinned {
    _pinned = pinned;
    [NSUserDefaults.standardUserDefaults setBool:pinned forKey:VTKeyPinned];
    [self notifyChanged];
}

- (void)setSilent:(BOOL)silent {
    _silent = silent;
    [NSUserDefaults.standardUserDefaults setBool:silent forKey:VTKeySilent];
    [self rescheduleNotificationIfNeeded];
    [self notifyChanged];
}

- (void)setHapticsEnabled:(BOOL)hapticsEnabled {
    _hapticsEnabled = hapticsEnabled;
    [NSUserDefaults.standardUserDefaults setBool:hapticsEnabled forKey:VTKeyHaptics];
    [self notifyChanged];
}

- (NSString *)formattedRemaining {
    NSInteger totalSeconds = MAX(0, (NSInteger)ceil(self.remaining));
    return [NSString stringWithFormat:@"%02ld:%02ld", totalSeconds / 60, totalSeconds % 60];
}

- (NSString *)statusText {
    if (self.running) { return @"Running"; }
    if (self.remaining > 0) { return @"Paused"; }
    return @"Ready";
}

- (CGFloat)visualFraction {
    if (self.remaining <= 0) { return 0; }
    return MIN(1, MAX(0, self.remaining / VTMaximumDuration));
}

- (void)toggleStartPause {
    self.running ? [self pause] : [self start];
}

- (void)start {
    if (self.remaining <= 0) {
        self.remaining = self.configuredDuration;
    }

    if (self.remaining <= 0) { return; }

    self.deadline = [NSDate dateWithTimeIntervalSinceNow:self.remaining];
    self.running = YES;
    self.didFireCompletion = NO;
    [self persistTimerState];
    [self scheduleExpirationNotificationAfter:self.remaining soundEnabled:!self.silent];
    [self notifyChanged];
}

- (void)pause {
    if (!self.running) { return; }

    [self refreshRemaining];
    self.running = NO;
    self.deadline = nil;
    [self cancelExpirationNotification];
    [self persistTimerState];
    [self notifyChanged];
}

- (void)reset {
    self.running = NO;
    self.configuredDuration = 0;
    self.remaining = 0;
    self.deadline = nil;
    self.didFireCompletion = NO;
    [self cancelExpirationNotification];
    [self persistTimerState];
    [self notifyChanged];
}

- (void)setDurationFromPoint:(NSPoint)point inSize:(NSSize)size {
    NSPoint center = NSMakePoint(size.width / 2, size.height / 2);
    CGFloat dx = point.x - center.x;
    CGFloat dy = point.y - center.y;
    if (hypot(dx, dy) <= 6) { return; }

    CGFloat angle = atan2(dy, dx) * 180 / M_PI;
    CGFloat counterClockwiseDegrees = [self normalizedDegrees:-90 - angle];
    CGFloat rawMinutes = counterClockwiseDegrees / 360 * 60;
    CGFloat roundedMinutes = rawMinutes >= 59.5 ? 60 : round(rawMinutes);

    [self setDurationMinutes:roundedMinutes];
}

- (void)setDurationMinutes:(CGFloat)minutes {
    if (self.running) {
        [self pause];
    }

    CGFloat clampedMinutes = MIN(60, MAX(0, minutes));
    NSTimeInterval seconds = clampedMinutes * 60;
    self.configuredDuration = seconds;
    self.remaining = seconds;
    self.deadline = nil;
    self.didFireCompletion = seconds == 0;
    [self persistTimerState];
    [self notifyChanged];
}

- (void)startDisplayTimer {
    [self.displayTimer invalidate];
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         target:self
                                                       selector:@selector(timerDidTick:)
                                                       userInfo:nil
                                                        repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.displayTimer forMode:NSRunLoopCommonModes];
}

- (void)timerDidTick:(NSTimer *)timer {
    [self refreshRemaining];
}

- (void)refreshRemaining {
    if (!self.running || !self.deadline) { return; }

    self.remaining = MAX(0, self.deadline.timeIntervalSinceNow);
    if (self.remaining <= 0) {
        [self finishTimer];
    } else {
        [self notifyChanged];
    }
}

- (void)finishTimer {
    if (self.didFireCompletion) { return; }

    self.didFireCompletion = YES;
    self.running = NO;
    self.configuredDuration = 0;
    self.remaining = 0;
    self.deadline = nil;
    [self persistTimerState];

    if (NSApp.isActive && !self.silent) {
        NSSound *sound = [NSSound soundNamed:@"Glass"];
        sound ? [sound play] : NSBeep();
    }

    if (self.hapticsEnabled) {
        [NSHapticFeedbackManager.defaultPerformer performFeedbackPattern:NSHapticFeedbackPatternGeneric
                                                         performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }

    [self notifyChanged];
}

- (void)scheduleExpirationNotificationAfter:(NSTimeInterval)seconds soundEnabled:(BOOL)soundEnabled {
    [self cancelExpirationNotification];

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [NSString stringWithFormat:@"%@ complete", VTAppDisplayName];
    content.body = @"Your redrunner timer is done.";
    if (soundEnabled) {
        content.sound = UNNotificationSound.defaultSound;
    }

    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:MAX(1, seconds)
                                                                                                    repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:VTNotificationIdentifier
                                                                          content:content
                                                                          trigger:trigger];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)cancelExpirationNotification {
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[VTNotificationIdentifier]];
}

- (void)rescheduleNotificationIfNeeded {
    if (self.running && self.remaining > 0) {
        [self scheduleExpirationNotificationAfter:self.remaining soundEnabled:!self.silent];
    }
}

- (void)persistTimerState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.configuredDuration forKey:VTKeyConfiguredDuration];
    [defaults setDouble:self.remaining forKey:VTKeyRemaining];
    [defaults setBool:self.running forKey:VTKeyRunning];
    if (self.deadline) {
        [defaults setObject:self.deadline forKey:VTKeyDeadline];
    } else {
        [defaults removeObjectForKey:VTKeyDeadline];
    }
}

- (CGFloat)normalizedDegrees:(CGFloat)value {
    CGFloat result = fmod(value, 360);
    return result >= 0 ? result : result + 360;
}

- (void)notifyChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:VTTimerModelDidChangeNotification object:self];
    [self.delegate timerModelDidChange:self];
}

@end

@interface VTTimerFaceView : NSView
@property (nonatomic, strong) VTTimerModel *model;
@end

@implementation VTTimerFaceView

- (instancetype)initWithModel:(VTTimerModel *)model {
    self = [super initWithFrame:NSZeroRect];
    if (!self) { return nil; }
    _model = model;
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self updateDurationWithEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self updateDurationWithEvent:event];
}

- (void)updateDurationWithEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.model setDurationFromPoint:point inSize:self.bounds.size];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGFloat side = MIN(NSWidth(self.bounds), NSHeight(self.bounds));
    NSRect square = NSMakeRect((NSWidth(self.bounds) - side) / 2,
                               (NSHeight(self.bounds) - side) / 2,
                               side,
                               side);
    NSPoint center = NSMakePoint(NSMidX(square), NSMidY(square));
    CGFloat cornerRadius = side * 0.075;
    CGFloat redRadius = side * 0.305;
    CGFloat tickOuterRadius = side * 0.34;

    NSGraphicsContext *graphicsContext = NSGraphicsContext.currentContext;
    [graphicsContext saveGraphicsState];

    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.18];
    shadow.shadowBlurRadius = 10;
    shadow.shadowOffset = NSMakeSize(0, -4);
    [shadow set];

    NSBezierPath *framePath = [NSBezierPath bezierPathWithRoundedRect:square
                                                              xRadius:cornerRadius
                                                              yRadius:cornerRadius];
    [NSColor.whiteColor setFill];
    [framePath fill];

    [graphicsContext restoreGraphicsState];

    [[NSColor colorWithWhite:0 alpha:0.12] setStroke];
    framePath.lineWidth = MAX(1, side * 0.008);
    [framePath stroke];

    [self drawRedDiskWithCenter:center radius:redRadius];
    [self drawTickMarksWithCenter:center outerRadius:tickOuterRadius side:side];
    [self drawNumbersWithCenter:center radius:side * 0.395 side:side];
    [self drawHandleWithCenter:center radius:redRadius side:side];

    NSBezierPath *hub = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - side * 0.024,
                                                                          center.y - side * 0.024,
                                                                          side * 0.048,
                                                                          side * 0.048)];
    [NSColor.blackColor setFill];
    [hub fill];
}

- (void)drawRedDiskWithCenter:(NSPoint)center radius:(CGFloat)radius {
    CGFloat fraction = self.model.visualFraction;
    if (fraction <= 0) { return; }

    NSColor *red = [NSColor colorWithCalibratedRed:0.933 green:0.110 blue:0.145 alpha:1];

    if (fraction >= 0.999) {
        [red setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - radius,
                                                           center.y - radius,
                                                           radius * 2,
                                                           radius * 2)] fill];
        return;
    }

    NSInteger steps = MAX(3, (NSInteger)ceil(220 * fraction));
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:center];

    for (NSInteger step = 0; step <= steps; step++) {
        CGFloat progress = (CGFloat)step / (CGFloat)steps;
        CGFloat angle = (-90 - (fraction * 360 * progress)) * M_PI / 180;
        NSPoint point = NSMakePoint(center.x + cos(angle) * radius,
                                    center.y + sin(angle) * radius);
        [path lineToPoint:point];
    }

    [path closePath];
    [red setFill];
    [path fill];
}

- (void)drawTickMarksWithCenter:(NSPoint)center outerRadius:(CGFloat)outerRadius side:(CGFloat)side {
    for (NSInteger minute = 0; minute < 60; minute++) {
        BOOL major = minute % 5 == 0;
        CGFloat innerRadius = outerRadius - (major ? side * 0.032 : side * 0.018);
        CGFloat angle = (-90 - ((CGFloat)minute / 60 * 360)) * M_PI / 180;
        NSPoint start = NSMakePoint(center.x + cos(angle) * innerRadius,
                                    center.y + sin(angle) * innerRadius);
        NSPoint end = NSMakePoint(center.x + cos(angle) * outerRadius,
                                  center.y + sin(angle) * outerRadius);

        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:start];
        [tick lineToPoint:end];
        tick.lineWidth = major ? MAX(1.4, side * 0.004) : MAX(0.8, side * 0.002);
        [[NSColor.blackColor colorWithAlphaComponent:major ? 0.72 : 0.50] setStroke];
        [tick stroke];
    }
}

- (void)drawNumbersWithCenter:(NSPoint)center radius:(CGFloat)radius side:(CGFloat)side {
    NSArray<NSNumber *> *labels = @[@5, @10, @15, @20, @25, @30, @35, @40, @45, @50, @55, @0];
    NSFont *font = [NSFont systemFontOfSize:side * 0.075 weight:NSFontWeightBold];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor.blackColor colorWithAlphaComponent:0.82],
        NSParagraphStyleAttributeName: style
    };

    for (NSNumber *number in labels) {
        CGFloat minute = number.doubleValue;
        CGFloat angle = (-90 - (minute / 60 * 360)) * M_PI / 180;
        NSString *text = number.stringValue;
        NSSize textSize = [text sizeWithAttributes:attributes];
        NSPoint point = NSMakePoint(center.x + cos(angle) * radius,
                                    center.y + sin(angle) * radius);
        NSRect rect = NSMakeRect(point.x - textSize.width / 2,
                                 point.y - textSize.height / 2,
                                 textSize.width,
                                 textSize.height);
        [text drawInRect:rect withAttributes:attributes];
    }
}

- (void)drawHandleWithCenter:(NSPoint)center radius:(CGFloat)radius side:(CGFloat)side {
    CGFloat fraction = self.model.visualFraction;
    if (fraction <= 0) { return; }

    CGFloat angle = (-90 - (fraction * 360)) * M_PI / 180;
    NSPoint point = NSMakePoint(center.x + cos(angle) * radius,
                                center.y + sin(angle) * radius);
    CGFloat handleSize = side * 0.032;
    NSRect rect = NSMakeRect(point.x - handleSize / 2,
                             point.y - handleSize / 2,
                             handleSize,
                             handleSize);
    NSBezierPath *handle = [NSBezierPath bezierPathWithOvalInRect:rect];
    [NSColor.whiteColor setFill];
    [handle fill];
    [[NSColor.blackColor colorWithAlphaComponent:0.85] setStroke];
    handle.lineWidth = MAX(1, side * 0.003);
    [handle stroke];
}

@end

@interface VTRootView : NSView <VTTimerModelDelegate>
@property (nonatomic, strong) VTTimerModel *model;
@property (nonatomic, strong) NSTextField *readoutLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) VTTimerFaceView *faceView;
@property (nonatomic, strong) NSButton *pinButton;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *resetButton;
@property (nonatomic, strong) NSButton *silentButton;
@property (nonatomic, strong) NSButton *hapticButton;
@end

@implementation VTRootView

- (instancetype)initWithModel:(VTTimerModel *)model {
    self = [super initWithFrame:NSMakeRect(0, 0, 520, 660)];
    if (!self) { return nil; }

    _model = model;
    _model.delegate = self;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    [self buildSubviews];
    [self updateUI];
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
    [self applyWindowPin];
}

- (void)keyDown:(NSEvent *)event {
    if ([event.charactersIgnoringModifiers isEqualToString:@" "]) {
        [self.model toggleStartPause];
    } else {
        [super keyDown:event];
    }
}

- (void)buildSubviews {
    self.readoutLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:44 weight:NSFontWeightBold]
                                      color:NSColor.labelColor];
    self.statusLabel = [self labelWithFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                     color:NSColor.secondaryLabelColor];

    self.pinButton = [self checkboxWithTitle:@"Pin" action:@selector(pinChanged:)];
    self.faceView = [[VTTimerFaceView alloc] initWithModel:self.model];
    self.faceView.translatesAutoresizingMaskIntoConstraints = NO;

    self.startButton = [self pushButtonWithTitle:@"Start" symbol:@"play.fill" action:@selector(startPausePressed:)];
    self.startButton.keyEquivalent = @" ";
    self.resetButton = [self pushButtonWithTitle:@"Reset" symbol:@"arrow.counterclockwise" action:@selector(resetPressed:)];

    self.silentButton = [self checkboxWithTitle:@"Silent" action:@selector(silentChanged:)];
    self.hapticButton = [self checkboxWithTitle:@"Haptic" action:@selector(hapticChanged:)];

    for (NSView *view in @[self.readoutLabel, self.statusLabel, self.pinButton, self.faceView, self.startButton, self.resetButton, self.silentButton, self.hapticButton]) {
        [self addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.readoutLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
        [self.readoutLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:22],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.readoutLabel.leadingAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.readoutLabel.bottomAnchor constant:2],

        [self.pinButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        [self.pinButton.centerYAnchor constraintEqualToAnchor:self.readoutLabel.centerYAnchor],

        [self.faceView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:18],
        [self.faceView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
        [self.faceView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        [self.faceView.heightAnchor constraintEqualToAnchor:self.faceView.widthAnchor],

        [self.startButton.topAnchor constraintEqualToAnchor:self.faceView.bottomAnchor constant:20],
        [self.startButton.trailingAnchor constraintEqualToAnchor:self.centerXAnchor constant:-6],
        [self.startButton.widthAnchor constraintGreaterThanOrEqualToConstant:112],

        [self.resetButton.topAnchor constraintEqualToAnchor:self.startButton.topAnchor],
        [self.resetButton.leadingAnchor constraintEqualToAnchor:self.centerXAnchor constant:6],
        [self.resetButton.widthAnchor constraintGreaterThanOrEqualToConstant:112],

        [self.silentButton.topAnchor constraintEqualToAnchor:self.startButton.bottomAnchor constant:16],
        [self.silentButton.trailingAnchor constraintEqualToAnchor:self.centerXAnchor constant:-9],

        [self.hapticButton.centerYAnchor constraintEqualToAnchor:self.silentButton.centerYAnchor],
        [self.hapticButton.leadingAnchor constraintEqualToAnchor:self.centerXAnchor constant:9],
        [self.hapticButton.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-20]
    ]];
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    return label;
}

- (NSButton *)pushButtonWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeLarge;
    if (@available(macOS 11.0, *)) {
        button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        button.imagePosition = NSImageLeading;
    }
    return button;
}

- (NSButton *)checkboxWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton checkboxWithTitle:title target:self action:action];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.controlSize = NSControlSizeSmall;
    return button;
}

- (void)pinChanged:(NSButton *)sender {
    self.model.pinned = sender.state == NSControlStateValueOn;
    [self applyWindowPin];
}

- (void)silentChanged:(NSButton *)sender {
    self.model.silent = sender.state == NSControlStateValueOn;
}

- (void)hapticChanged:(NSButton *)sender {
    self.model.hapticsEnabled = sender.state == NSControlStateValueOn;
}

- (void)startPausePressed:(NSButton *)sender {
    [self.model toggleStartPause];
}

- (void)resetPressed:(NSButton *)sender {
    [self.model reset];
}

- (void)timerModelDidChange:(VTTimerModel *)model {
    [self updateUI];
}

- (void)updateUI {
    self.readoutLabel.stringValue = self.model.formattedRemaining;
    self.statusLabel.stringValue = self.model.statusText;

    self.pinButton.state = self.model.pinned ? NSControlStateValueOn : NSControlStateValueOff;
    self.silentButton.state = self.model.silent ? NSControlStateValueOn : NSControlStateValueOff;
    self.hapticButton.state = self.model.hapticsEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    self.startButton.title = self.model.running ? @"Pause" : @"Start";
    if (@available(macOS 11.0, *)) {
        self.startButton.image = [NSImage imageWithSystemSymbolName:self.model.running ? @"pause.fill" : @"play.fill"
                                           accessibilityDescription:nil];
    }

    [self applyWindowPin];
    [self.faceView setNeedsDisplay:YES];
}

- (void)applyWindowPin {
    if (!self.window) { return; }

    self.window.level = self.model.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    if (self.model.pinned) {
        self.window.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    } else {
        self.window.collectionBehavior &= ~(NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary);
    }
}

@end

@interface VTAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) VTTimerModel *model;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSMenuItem *statusRemainingItem;
@property (nonatomic, strong) NSMenuItem *statusStartPauseItem;
@property (nonatomic, strong) NSMenuItem *statusPinItem;
@property (nonatomic, strong) NSMenuItem *statusSilentItem;
@end

@implementation VTAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self installAppIcon];
    [self installMenu];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                                                      completionHandler:^(BOOL granted, NSError * _Nullable error) {}];

    self.model = [VTTimerModel new];
    [self installStatusItem];

    NSRect frame = NSMakeRect(0, 0, 520, 660);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = VTAppDisplayName;
    self.window.releasedWhenClosed = NO;
    self.window.minSize = NSMakeSize(430, 580);
    self.window.contentView = [[VTRootView alloc] initWithModel:self.model];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(timerModelDidChange:)
                                               name:VTTimerModelDidChangeNotification
                                             object:self.model];
    [self updateStatusItem];
}

- (void)installAppIcon {
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"redrunner" ofType:@"icns"];
    NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (icon) {
        NSApp.applicationIconImage = icon;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) {
        [self.window makeKeyAndOrderFront:nil];
    }
    return YES;
}

- (void)timerModelDidChange:(NSNotification *)notification {
    [self updateStatusItem];
}

- (void)installStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];

    NSStatusBarButton *button = self.statusItem.button;
    button.toolTip = VTAppDisplayName;
    button.imagePosition = NSImageLeading;
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:@"timer" accessibilityDescription:VTAppDisplayName];
        image.template = YES;
        button.image = image;
    }

    self.statusMenu = [NSMenu new];
    self.statusMenu.delegate = self;

    self.statusRemainingItem = [[NSMenuItem alloc] initWithTitle:@"Ready"
                                                          action:nil
                                                   keyEquivalent:@""];
    self.statusRemainingItem.enabled = NO;
    [self.statusMenu addItem:self.statusRemainingItem];
    [self.statusMenu addItem:NSMenuItem.separatorItem];

    self.statusStartPauseItem = [[NSMenuItem alloc] initWithTitle:@"Start"
                                                           action:@selector(statusStartPausePressed:)
                                                    keyEquivalent:@""];
    self.statusStartPauseItem.target = self;
    [self.statusMenu addItem:self.statusStartPauseItem];

    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset"
                                                       action:@selector(statusResetPressed:)
                                                keyEquivalent:@""];
    resetItem.target = self;
    [self.statusMenu addItem:resetItem];

    [self.statusMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *addOne = [[NSMenuItem alloc] initWithTitle:@"Add 1 Minute"
                                                    action:@selector(statusAddOneMinute:)
                                             keyEquivalent:@""];
    addOne.target = self;
    [self.statusMenu addItem:addOne];

    NSMenuItem *addFive = [[NSMenuItem alloc] initWithTitle:@"Add 5 Minutes"
                                                     action:@selector(statusAddFiveMinutes:)
                                              keyEquivalent:@""];
    addFive.target = self;
    [self.statusMenu addItem:addFive];

    NSMenuItem *addFifteen = [[NSMenuItem alloc] initWithTitle:@"Add 15 Minutes"
                                                        action:@selector(statusAddFifteenMinutes:)
                                                 keyEquivalent:@""];
    addFifteen.target = self;
    [self.statusMenu addItem:addFifteen];

    [self.statusMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *showWindowItem = [[NSMenuItem alloc] initWithTitle:@"Show Timer"
                                                            action:@selector(statusShowWindow:)
                                                     keyEquivalent:@""];
    showWindowItem.target = self;
    [self.statusMenu addItem:showWindowItem];

    self.statusPinItem = [[NSMenuItem alloc] initWithTitle:@"Pin Window on Top"
                                                    action:@selector(statusPinPressed:)
                                             keyEquivalent:@""];
    self.statusPinItem.target = self;
    [self.statusMenu addItem:self.statusPinItem];

    self.statusSilentItem = [[NSMenuItem alloc] initWithTitle:@"Silent Mode"
                                                       action:@selector(statusSilentPressed:)
                                                keyEquivalent:@""];
    self.statusSilentItem.target = self;
    [self.statusMenu addItem:self.statusSilentItem];

    [self.statusMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", VTAppDisplayName]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [self.statusMenu addItem:quitItem];

    self.statusItem.menu = self.statusMenu;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateStatusItem];
}

- (void)updateStatusItem {
    if (!self.statusItem) { return; }

    self.statusItem.button.title = [self shortMenuBarTitle];
    self.statusRemainingItem.title = [NSString stringWithFormat:@"%@ - %@",
                                      self.model.statusText,
                                      self.model.formattedRemaining];
    self.statusStartPauseItem.title = self.model.running ? @"Pause" : @"Start";
    self.statusStartPauseItem.enabled = self.model.remaining > 0;
    self.statusPinItem.state = self.model.pinned ? NSControlStateValueOn : NSControlStateValueOff;
    self.statusSilentItem.state = self.model.silent ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSString *)shortMenuBarTitle {
    NSInteger totalSeconds = MAX(0, (NSInteger)ceil(self.model.remaining));
    if (totalSeconds <= 0) {
        return @"0m";
    }

    NSInteger minutes = (NSInteger)ceil((double)totalSeconds / 60.0);
    return [NSString stringWithFormat:@"%ldm", minutes];
}

- (void)statusStartPausePressed:(id)sender {
    [self.model toggleStartPause];
}

- (void)statusResetPressed:(id)sender {
    [self.model reset];
}

- (void)statusAddOneMinute:(id)sender {
    [self addMinutesFromStatusItem:1];
}

- (void)statusAddFiveMinutes:(id)sender {
    [self addMinutesFromStatusItem:5];
}

- (void)statusAddFifteenMinutes:(id)sender {
    [self addMinutesFromStatusItem:15];
}

- (void)addMinutesFromStatusItem:(NSInteger)minutes {
    BOOL wasRunning = self.model.running;
    NSTimeInterval newRemaining = MIN(VTMaximumDuration, self.model.remaining + minutes * 60);
    [self.model setDurationMinutes:newRemaining / 60.0];
    if (wasRunning) {
        [self.model start];
    }
}

- (void)statusShowWindow:(id)sender {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)statusPinPressed:(id)sender {
    self.model.pinned = !self.model.pinned;
}

- (void)statusSilentPressed:(id)sender {
    self.model.silent = !self.model.silent;
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)installMenu {
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appMenuItem = [NSMenuItem new];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [NSMenu new];
    NSString *quitTitle = [NSString stringWithFormat:@"Quit %@", NSProcessInfo.processInfo.processName];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];
    NSApp.mainMenu = mainMenu;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (VTRelaunchAppBundleIfRawExecutableLaunch(argv[0])) {
            return 0;
        }

        NSApplication *application = NSApplication.sharedApplication;
        VTAppDelegate *delegate = [VTAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
