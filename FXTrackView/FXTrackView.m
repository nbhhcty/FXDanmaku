//
//  FXTrackView.m
//
//
//  Created by ShawnFoo on 12/4/15.
//  Copyright © 2015 ShawnFoo. All rights reserved.
//

#import "FXTrackView.h"
#import <pthread.h>
#import "FXTrackViewHeader.h"
#import "FXDeallocMonitor.h"
#import "FXReusableObjectQueue.h"
#import "FXTrackViewItem.h"
#import "FXSingleRowItemsManager.h"

typedef NS_ENUM(NSUInteger, TrackViewStatus) {
    StatusNotStarted = 1001,
    StatusRunning,
    StatusPaused,
    StatusStoped
};

@interface FXTrackView () {
    pthread_mutex_t _track_mutex;
    pthread_cond_t _track_prod, _track_cons;
    pthread_mutex_t _data_mutex;
    pthread_cond_t _data_prod, _data_cons;
    
    __block TrackViewStatus _status;
    __block BOOL _hasTracks;
    __block BOOL _hasData;
}

@property (assign, nonatomic) BOOL hasCalcTracks;
@property (assign, nonatomic) NSInteger numOfTracks;

@property (assign, nonatomic) CGRect trackViewFrame;
@property (assign, nonatomic) CGFloat trackHeight;
@property (nonatomic, strong) NSMutableArray<FXTrackViewData *> *dataQueue;
@property (nonatomic, strong) FXReusableObjectQueue *reuseItemQueue;

@property (strong, nonatomic) dispatch_queue_t consumerQueue;
@property (strong, nonatomic) dispatch_queue_t trackProducerQueue;
@property (strong, nonatomic) dispatch_queue_t dataProducerQueue;

@property (assign, nonatomic) NSUInteger occupiedTrackMaskBit;

@property (nonatomic, strong) NSMutableDictionary<NSNumber *, FXSingleRowItemsManager *> *rowItemsManager;

@property (nonatomic, readonly) BOOL shouldAcceptData;

@end

@implementation FXTrackView

#pragma mark - Setter & Getter

#pragma mark Setter

- (void)setMaxVelocity:(NSUInteger)maxVelocity {
    if (maxVelocity >= _minVelocity) {
        _maxVelocity = maxVelocity;
    }
    else { LogD(@"MaxVelocity can't be slower than minVelocity!😪"); }
}

#pragma mark Lazy Loading

- (dispatch_queue_t)consumerQueue {
    if (!_consumerQueue) {
        _consumerQueue = dispatch_queue_create("shawnfoo.trackView.consumerQueue", NULL);
    }
    return _consumerQueue;
}

- (dispatch_queue_t)trackProducerQueue {
    if (!_trackProducerQueue) {
        _trackProducerQueue = dispatch_queue_create("shawnfoo.trackView.trackProducerQueue", NULL);
    }
    return _trackProducerQueue;
}

- (dispatch_queue_t)dataProducerQueue {
    if (!_dataProducerQueue) {
        _dataProducerQueue = dispatch_queue_create("shawnfoo.trackView.dataProducerQueue", NULL);
    }
    return _dataProducerQueue;
}

- (NSMutableArray<FXTrackViewData *> *)dataQueue {
    if (!_dataQueue) {
        _dataQueue = [NSMutableArray array];
    }
    return _dataQueue;
}

- (FXReusableObjectQueue *)reuseItemQueue {
    if (!_reuseItemQueue) {
        _reuseItemQueue = [FXReusableObjectQueue queue];
    }
    return _reuseItemQueue;
}

- (NSMutableDictionary<NSNumber *, FXSingleRowItemsManager *> *)rowItemsManager {
    if (!_rowItemsManager) {
        _rowItemsManager = [NSMutableDictionary dictionaryWithCapacity:_numOfTracks];
    }
    return _rowItemsManager;
}

#pragma mark Shortcut Accessory
- (FXSingleRowItemsManager *)rowItemsManagerAtRow:(NSUInteger)row {
    
    FXSingleRowItemsManager *manager = self.rowItemsManager[@(row)];
    if (!manager) {
        manager = [[FXSingleRowItemsManager alloc] init];
        self.rowItemsManager[@(row)] = manager;
    }
    return manager;
}

#pragma mark Computed Property

- (BOOL)isRunning {
    return StatusRunning == _status;
}

- (BOOL)shouldAcceptData {
    
    BOOL notStoped = StatusStoped != _status;
    return notStoped || (!notStoped && _acceptDataWhenPaused);
}

#pragma mark - LifeCycle

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self commonSetup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self commonSetup];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    if (!_hasCalcTracks && CGSizeNotZero(self.frame.size)) {
        _hasCalcTracks = YES;
        [self calcTrackNumAndHeight];
    }
}

- (void)removeFromSuperview {
    [super removeFromSuperview];
    
    if (StatusStoped != _status) {
        LogD(@"You should call 'stop' method before removing trackView from its superview!");
        [self stop];
    }
}

- (void)dealloc {
    
    pthread_mutex_destroy(&_track_mutex);
    pthread_mutex_destroy(&_data_mutex);
    pthread_cond_destroy(&_track_prod);
    pthread_cond_destroy(&_track_cons);
    pthread_cond_destroy(&_data_prod);
    pthread_cond_destroy(&_data_cons);
}

#pragma mark - Layout

- (void)commonSetup {
    
    // setup default value
    _status = StatusNotStarted;
    _maxVelocity = !_maxVelocity ? FX_MaxVelocity : _maxVelocity;
    _minVelocity = !_minVelocity ? FX_MinVelocity : _minVelocity;
    _randomTrack = NO;
    _cleanScreenWhenPaused = NO;
    _emptyDataWhenPaused = NO;
    _acceptDataWhenPaused = YES;
    _removeFromSuperViewWhenStoped = NO;
    _hasCalcTracks = NO;
    self.layer.masksToBounds = YES;
    
#ifdef FX_TrackViewBackgroundColor
    self.backgroundColor = FX_TrackViewBackgroundColor;
#else
    self.backgroundColor = [UIColor clearColor];
#endif
    
    pthread_mutex_init(&_track_mutex, NULL);
    pthread_cond_init(&_track_prod, NULL);
    pthread_cond_init(&_track_cons, NULL);
    
    pthread_mutex_init(&_data_mutex, NULL);
    pthread_cond_init(&_data_prod, NULL);
    pthread_cond_init(&_data_cons, NULL);
    
    [FXDeallocMonitor addMonitorToObj:self];
}

- (void)calcTrackNumAndHeight {
    
    if (StatusRunning != _status) {
        CGFloat height = self.frame.size.height;
        
        // height = numOfTrack * estimatedTrackHeight + (numOfTrack-1) * trackVerticalSpan
        // According to the formula above, you'll understand the statements below
        self.numOfTracks = floor((height+FX_TrackVSpan) / (FX_EstimatedTrackHeight+FX_TrackVSpan));
        self.trackHeight = (height - (self.numOfTracks-1)*FX_TrackVSpan) / self.numOfTracks;
        
        _hasTracks = self.numOfTracks > 0;
    }
}

- (void)frameDidChange {
    if (StatusRunning != _status) {
        [self calcTrackNumAndHeight];
    }
    else {
        LogD(@"Please pause or stop trackView before calling 'frameDidChange' method");
    }
}

#pragma mark - Register

- (void)registerNib:(UINib *)nib forItemReuseIdentifier:(NSString *)identifier {
    if (identifier) {
        [self.reuseItemQueue registerNib:nib forObjectReuseIdentifier:identifier];
    }
}

- (void)registerClass:(Class)itemClass forItemReuseIdentifier:(NSString *)identifier {
    if (identifier) {
        [self.reuseItemQueue registerClass:itemClass forObjectReuseIdentifier:identifier];
    }
}

#pragma mark - Data Input

- (void)addData:(FXTrackViewData *)data {
    
    if (!self.shouldAcceptData) {
        return;
    }
    dispatch_async(self.dataProducerQueue, ^{
        pthread_mutex_lock(&_data_mutex);
        if ([data isKindOfClass:[FXTrackViewData class]]) {
            [self insertData:data];
            if (!_hasData) {
                _hasData = YES;
                if (StatusRunning == _status) {
                    pthread_cond_signal(&_data_cons);
                }
            }
        }
        pthread_mutex_unlock(&_data_mutex);
    });
}

- (void)addDataArr:(NSArray *)dataArr {
    
    if (!self.shouldAcceptData) { return; }
    if (0 == dataArr.count) { return; }
    dispatch_async(self.dataProducerQueue, ^{
        pthread_mutex_lock(&_data_mutex);
        BOOL addedData = NO;
        for (FXTrackViewData *data in dataArr) {
            if ([data isKindOfClass:[FXTrackViewData class]]) {
                [self insertData:data];
                addedData = YES;
            }
        }
        if (!_hasData && addedData) {
            _hasData = YES;
            if (StatusRunning == _status) {
                pthread_cond_signal(&_data_cons);
            }
        }
        pthread_mutex_unlock(&_data_mutex);
    });
}

#pragma mark - Actions

- (void)start {
    RunBlock_Safe_MainThread(^{
        if (StatusRunning != _status && CGSizeNotZero(self.frame.size)) {
            _status = StatusRunning;
            [self startConsuming];
        }
    });
}

- (void)pause {
    RunBlock_Safe_MainThread(^{
        if (StatusRunning == _status) {
            _status = StatusPaused;
            [self stopConsuming];
            if (_cleanScreenWhenPaused) {
                [self cleanScreen];
            }
        }
    });
}

- (void)stop {
    RunBlock_Safe_MainThread(^{
        if (StatusStoped != _status) {
            _status = StatusStoped;
            [self stopConsuming];
            [self cleanScreen];
            if (_removeFromSuperViewWhenStoped) {
                [self removeFromSuperview];
            }
        }
    });
}

- (void)startConsuming {
    dispatch_async(self.consumerQueue, ^{
        [self consumeData];
    });
}

- (void)stopConsuming {
    
    // Exit the consumer thread if waiting! Otherwise, self can't be released! Memory leaks!
    if (!_hasTracks) {
        pthread_mutex_lock(&_track_mutex);
        _hasTracks = YES;
        pthread_cond_signal(&_track_cons);
        pthread_mutex_unlock(&_track_mutex);
    }
    if (!_hasData) {
        pthread_mutex_lock(&_data_mutex);
        _hasData = YES;
        pthread_cond_signal(&_data_cons);
        pthread_mutex_unlock(&_data_mutex);
    }
}

- (void)cleanScreen {
    
    for (UIView *subViews in self.subviews) {
        [subViews removeFromSuperview];
    }
}

#pragma mark - Data Producer & Consumer

- (FXTrackViewData *)fetchData {
    
    pthread_mutex_lock(&_data_mutex);
    while (!_hasData) {// no carriers, waiting for producer to signal to consumer
        pthread_cond_wait(&_data_cons, &_data_mutex);
    }
    FXTrackViewData *data = nil;
    if (StatusRunning == _status) {
        data = self->_dataQueue.firstObject;
        if (data) {
            [self->_dataQueue removeObjectAtIndex:0];
        }
        _hasData = self->_dataQueue.count > 0;
    }
    pthread_mutex_unlock(&_data_mutex);
    return data;
}

- (void)insertData:(FXTrackViewData *)data {
    
    if (FXDataPriorityHigh == data.priority) {
        [self.dataQueue insertObject:data atIndex:0];
    }
    else {
        [self.dataQueue addObject:data];
    }
}

#pragma mark - Track Producer & Consumer

- (NSInteger)fetchRandomUnoccupiedTrackIndex {
    
    pthread_mutex_lock(&_track_mutex);
    while (!_hasTracks) {
        pthread_cond_wait(&_track_cons, &_track_mutex);
    }
    
    NSInteger index = -1;
    if (StatusRunning == _status) {
        
        UInt8 *array = NULL;
        int n = 0;
        for (int i = 0; i < self.numOfTracks; i++) {
            if (1<<i & _occupiedTrackMaskBit) {
                continue;
            }
            if (!array) {
                array = malloc(sizeof(UInt8)*(self.numOfTracks-i));
            }
            array[n++] = i;
        }
        if (array) {
            index = array[arc4random()%n];
            [self setOccupiedTrackAtIndex:index];
            _hasTracks = n > 1 ? YES : NO;
            free(array);
        }
        else {
            _hasTracks = NO;
        }
    }
    
    pthread_mutex_unlock(&_track_mutex);
    return index;
}

- (NSInteger)fetchOrderedUnoccupiedTrackIndexFromBottom {
    
    pthread_mutex_lock(&_track_mutex);
    while (!_hasTracks) {
        pthread_cond_wait(&_track_cons, &_track_mutex);
    }
    NSInteger index = -1;
    if (StatusRunning == _status) {
        BOOL hasTracks = NO;
        for (NSInteger i = self.numOfTracks-1; i > -1; i--) {
            if (1<<i & _occupiedTrackMaskBit) {
                continue;
            }
            else if (-1 == index) {
                index = i;
            }
            else {
                hasTracks = YES;
                break;
            }
        }
        if (index > -1) {
            [self setOccupiedTrackAtIndex:index];
        }
        _hasTracks = hasTracks;
    }
    
    pthread_mutex_unlock(&_track_mutex);
    return index;
}

- (NSInteger)fetchOrderedUnoccupiedTrackIndexFromTop {
    
    pthread_mutex_lock(&_track_mutex);
    while (!_hasTracks) {
        pthread_cond_wait(&_track_cons, &_track_mutex);
    }
    
    NSInteger index = -1;
    if (StatusRunning == _status) {
        BOOL hasTracks = NO;
        for (int i = 0; i < self.numOfTracks; i++) {
            if (1<<i & _occupiedTrackMaskBit) {
                continue;
            }
            else if (-1 == index) {
                index = i;
            }
            else {
                hasTracks = YES;
            }
        }
        if (index > -1) {
            [self setOccupiedTrackAtIndex:index];
        }
        _hasTracks = hasTracks;
    }
    
    pthread_mutex_unlock(&_track_mutex);
    return index;
}

- (void)setOccupiedTrackAtIndex:(NSInteger)index {
    
    if (index < self.numOfTracks) {
        self.occupiedTrackMaskBit |= 1 << index;
    }
}

- (void)removeOccupiedTrackAtIndex:(NSInteger)index {
    
    pthread_mutex_lock(&_track_mutex);
    if ((index<self.numOfTracks) && (1<<index & _occupiedTrackMaskBit)) {
        self.occupiedTrackMaskBit -= 1 << index;
        if (!_hasTracks) {
            _hasTracks = YES;
            pthread_cond_signal(&_track_cons);
        }
    }
    pthread_mutex_unlock(&_track_mutex);
}

#pragma mark - Animation Computation

- (NSUInteger)randomVelocity {
    if (self.maxVelocity == self.minVelocity) {
        return self.maxVelocity;
    }
    return arc4random()%(self.maxVelocity-self.minVelocity) + self.minVelocity;
}

- (NSTimeInterval)animateDurationOfVelocity:(NSUInteger)velocity itemWidth:(CGFloat)width {
    return (self.frame.size.width + width) / velocity;
}

- (CGPoint)startPointWithIndex:(NSUInteger)index {
    CGFloat yAxis = !index ? 0 : index*(self.trackHeight+FX_TrackVSpan);
    return CGPointMake(self.frame.size.width, yAxis);
}

#pragma mark - Item Presentation

- (void)consumeData {
    
    while (StatusRunning == _status) {
        FXTrackViewData *data = [self fetchData];
        if (data) {
            NSInteger unoccupiedIndex = self.randomTrack ? [self fetchRandomUnoccupiedTrackIndex] : [self fetchOrderedUnoccupiedTrackIndexFromBottom];
            if (unoccupiedIndex > -1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentData:data atIndex:unoccupiedIndex];
                });
            }
            else if (!self.emptyDataWhenPaused) {
                pthread_mutex_lock(&_data_mutex);
                [self.dataQueue insertObject:data atIndex:0];
                pthread_mutex_unlock(&_data_mutex);
            }
        }
    }
    LogD(@"stopConsuming");
    [self stopConsumingData];
}

- (void)stopConsumingData {
    
    BOOL stoped = StatusStoped == _status;
    BOOL paused = StatusPaused == _status;
    
    if (stoped || (paused&&_emptyDataWhenPaused)) {
        pthread_mutex_lock(&_data_mutex);
        [self->_dataQueue removeAllObjects];
        _hasData = NO;
        pthread_mutex_unlock(&_data_mutex);
    }
    
    pthread_mutex_lock(&_track_mutex);
    self.occupiedTrackMaskBit = 0;
    _hasTracks = YES;
    pthread_mutex_unlock(&_track_mutex);
}

- (void)presentData:(FXTrackViewData *)data atIndex:(NSUInteger)index {
    
    FXTrackViewItem *item = (FXTrackViewItem *)[self.reuseItemQueue dequeueReusableObjectWithIdentifier:data.itemReuseIdentifier];
    if (![item isKindOfClass:[FXTrackViewItem class]]) {
        LogD(@"Item(%@) is not kind of class FXTrackViewItem!", data.itemReuseIdentifier);
        return;
    }
    
    CGSize itemSize = item.frame.size;
    if (!itemSize.width) {
        itemSize = [item systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    }
    
    CGPoint point = [self startPointWithIndex:index];
    NSUInteger velocity = [self randomVelocity];
    NSTimeInterval animDuration = [self animateDurationOfVelocity:velocity itemWidth:itemSize.width];
    
    item.frame = CGRectMake(point.x, point.y , itemSize.width, self.trackHeight);
    CGRect toFrame = item.frame;
    toFrame.origin.x = -itemSize.width;
    
    [item layoutIfNeeded];
    [self addSubview:item];
    [self.rowItemsManager[@(index)] addTrackViewItem:item];
    
    [UIView animateWithDuration:animDuration
                          delay:0
                        options:UIViewAnimationOptionCurveLinear
                     animations:^
     {
         item.frame = toFrame;
         [self layoutIfNeeded];
     }
                     completion:^(BOOL finished)
     {
         [item removeFromSuperview];
         [self.rowItemsManager[@(index)] removeTrackViewItem:item];
         [self.reuseItemQueue enqueueReusableObject:item];
         
         dispatch_async(self.trackProducerQueue, ^{
             [self removeOccupiedTrackAtIndex:index];
         });
     }];
}

#pragma mark - Touch Dispatch

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (![self shouldHandleTouch:touches.anyObject]) {
        [super touchesBegan:touches withEvent:event];
    }
}

- (BOOL)shouldHandleTouch:(UITouch *)touch {
    
    CGPoint touchPoint = [touch locationInView:self];
    NSUInteger row = touchPoint.y / (self.trackHeight+FX_TrackVSpan);
    FXSingleRowItemsManager *manager = _rowItemsManager[@(row)];
    FXTrackViewItem *item = [manager itemAtPoint:touchPoint];
    if (item) {
        id<FXTrackViewDelegate> strongDelegate = self.delegate;
        if ([strongDelegate respondsToSelector:@selector(trackView:didClickItem:)]) {
            [strongDelegate trackView:self didClickItem:item];
            return YES;
        }
    }
    return NO;
}

@end
