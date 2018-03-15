//
//  TMLazyScrollView.m
//  LazyScrollView
//
//  Copyright (c) 2015-2018 Alibaba. All rights reserved.
//

#import "TMLazyScrollView.h"
#import <objc/runtime.h>
#import "TMLazyItemViewProtocol.h"
#import "UIView+TMLazyScrollView.h"
#import "TMLazyReusePool.h"
#import "TMLazyModelBucket.h"

#define LazyBufferHeight 20
#define LazyBucketHeight 400
void * const LazyObserverContext = "LazyObserverContext";

@interface TMLazyOuterScrollViewObserver: NSObject

@property (nonatomic, weak) TMLazyScrollView *lazyScrollView;

@end

//****************************************************************

@interface TMLazyScrollView () {
    NSMutableSet<UIView *> *_visibleItems;
    NSMutableSet<NSString *> *_inScreenVisibleMuiIDs;
    
    // Store item models.
    TMLazyModelBucket *_modelBucket;
    NSInteger _itemCount;
    
    // Store muiID of items which need to be reloaded.
    NSMutableSet<NSString *> *_needReloadingMuiIDs;
    
    // Store muiID of items which should be visible.
    NSMutableSet<NSString *> *_newVisibleMuiIDs;
    
    // Record current muiID of reloading item.
    // Will be used for dequeueReusableItem methods.
    NSString *_currentReloadingMuiID;
    
    // Store the enter screen times of items.
    NSMutableDictionary<NSString *, NSNumber *> *_enterTimesDict;

    // Record contentOffset of scrollView that used for calculating
    // views to show last time.
    CGPoint _lastContentOffset;
}

@property (nonatomic, strong) TMLazyOuterScrollViewObserver *outerScrollViewObserver;

- (void)outerScrollViewDidScroll;

@end

@implementation TMLazyScrollView

#pragma mark Getter & Setter

- (NSSet<UIView *> *)inScreenVisibleItems
{
    NSMutableSet<UIView *> * inScreenVisibleItems = [NSMutableSet set];
    for (UIView *view in _visibleItems) {
        if ([_inScreenVisibleMuiIDs containsObject:view.muiID]) {
            [inScreenVisibleItems addObject:view];
        }
    }
    return [inScreenVisibleItems copy];
}

- (NSSet<UIView *> *)visibleItems
{
    return [_visibleItems copy];
}

- (void)setDataSource:(id<TMLazyScrollViewDataSource>)dataSource
{
    if (_dataSource != dataSource) {
        if (dataSource == nil || [self isDataSourceValid:dataSource]) {
            _dataSource = dataSource;
#ifdef DEBUG
        } else {
            NSAssert(NO, @"TMLazyScrollView - Invalid dataSource.");
#endif
        }
    }
}

- (TMLazyOuterScrollViewObserver *)outerScrollViewObserver
{
    if (!_outerScrollViewObserver) {
        _outerScrollViewObserver = [TMLazyOuterScrollViewObserver new];
        _outerScrollViewObserver.lazyScrollView = self;
    }
    return _outerScrollViewObserver;
}

-(void)setOuterScrollView:(UIScrollView *)outerScrollView
{
    if (_outerScrollView != outerScrollView) {
        if (_outerScrollView) {
            [_outerScrollView removeObserver:self.outerScrollViewObserver forKeyPath:@"contentOffset" context:LazyObserverContext];
        }
        if (outerScrollView) {
            [outerScrollView addObserver:self.outerScrollViewObserver forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:LazyObserverContext];
        }
        _outerScrollView = outerScrollView;
    }
}

#pragma mark Lifecycle

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.clipsToBounds = YES;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        _autoClearGestures = YES;
        _loadAllItemsImmediately = YES;
        
        _reusePool = [TMLazyReusePool new];
        
        _visibleItems = [[NSMutableSet alloc] init];
        
        _inScreenVisibleMuiIDs = [NSMutableSet set];
        
        _modelBucket = [[TMLazyModelBucket alloc] initWithBucketHeight:LazyBucketHeight];
        
        _needReloadingMuiIDs = [[NSMutableSet alloc] init];
        
        _enterTimesDict = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    self.dataSource = nil;
    self.delegate = nil;
    self.outerScrollView = nil;
}

#pragma mark ScrollEvent

- (void)setContentOffset:(CGPoint)contentOffset
{
    [super setContentOffset:contentOffset];
    if (LazyBufferHeight < ABS(contentOffset.y - _lastContentOffset.y)) {
        _lastContentOffset = self.contentOffset;
        [self assembleSubviews:NO];
    }
}

- (void)outerScrollViewDidScroll
{
    if (LazyBufferHeight < ABS(self.outerScrollView.contentOffset.y - _lastContentOffset.y)) {
        _lastContentOffset = self.outerScrollView.contentOffset;
        [self assembleSubviews:NO];
    }
}

#pragma mark CoreLogic

- (void)assembleSubviews:(BOOL)isReload
{
    if (self.outerScrollView) {
        CGRect visibleArea = CGRectIntersection(self.outerScrollView.bounds, self.frame);
        if (visibleArea.size.height > 0) {
            CGFloat offsetY = CGRectGetMinY(self.frame);
            CGFloat minY = CGRectGetMinY(visibleArea) - offsetY;
            CGFloat maxY = CGRectGetMaxY(visibleArea) - offsetY;
            [self assembleSubviews:isReload minY:minY maxY:maxY];
        } else {
            [self assembleSubviews:isReload minY:0 maxY:-LazyBufferHeight * 2];
        }
    } else {
        CGFloat minY = CGRectGetMinY(self.bounds);
        CGFloat maxY = CGRectGetMaxY(self.bounds);
        [self assembleSubviews:isReload minY:minY maxY:maxY];
    }
}

- (void)recycleItems:(BOOL)isReload newVisibleMuiIDs:(NSSet<NSString *> *)newVisibleMuiIDs
{
    NSSet *visibleItemsCopy = [_visibleItems copy];
    for (UIView *itemView in visibleItemsCopy) {
        BOOL isToShow  = [newVisibleMuiIDs containsObject:itemView.muiID];
        if (!isToShow) {
            // Call didLeave.
            if ([itemView respondsToSelector:@selector(mui_didLeave)]){
                [(UIView<TMLazyItemViewProtocol> *)itemView mui_didLeave];
            }
            if (itemView.reuseIdentifier.length > 0) {
                itemView.hidden = YES;
                [self.reusePool addItemView:itemView forReuseIdentifier:itemView.reuseIdentifier];
                [_visibleItems removeObject:itemView];
            } else if(isReload && itemView.muiID) {
                [_needReloadingMuiIDs addObject:itemView.muiID];
            }
        } else if (isReload && itemView.muiID) {
            [_needReloadingMuiIDs addObject:itemView.muiID];
        }
    }
}

- (void)generateItems:(BOOL)isReload
{
    if (_newVisibleMuiIDs == nil || _newVisibleMuiIDs.count == 0) {
        return;
    }
    
    NSString *muiID = [_newVisibleMuiIDs anyObject];
    BOOL hasLoadAnItem = NO;
    
    // 1. Item view is not visible. We should create or reuse an item view.
    // 2. Item view need to be reloaded.
    BOOL isVisible = [self isMuiIdVisible:muiID];
    BOOL needReload = [_needReloadingMuiIDs containsObject:muiID];
    if (isVisible == NO || needReload == YES) {
        if (self.dataSource) {
            hasLoadAnItem = YES;
            // If you call dequeue method in your dataSource, the currentReloadingMuiID
            // will be used for searching the best-matched reusable view.
            if (isVisible == YES) {
                _currentReloadingMuiID = muiID;
            }
            UIView *itemView = [self.dataSource scrollView:self itemByMuiID:muiID];
            _currentReloadingMuiID = nil;
            
            if (itemView) {
                // Call afterGetView.
                if ([itemView respondsToSelector:@selector(mui_afterGetView)]) {
                    [(UIView<TMLazyItemViewProtocol> *)itemView mui_afterGetView];
                }
                // Show the item view.
                itemView.muiID = muiID;
                itemView.hidden = NO;
                if (self.autoAddSubview) {
                    if (itemView.superview != self) {
                        [self addSubview:itemView];
                    }
                }
                // Add item view to visibleItems.
                if (isVisible == NO) {
                    [_visibleItems addObject:itemView];
                    // Call didEnterWithTimes.
                    if ([itemView respondsToSelector:@selector(mui_didEnterWithTimes:)]) {
                        NSInteger times = [_enterTimesDict tm_integerForKey:itemView.muiID];
                        times++;
                        [_enterTimesDict tm_safeSetObject:@(times) forKey:itemView.muiID];
                        [(UIView<TMLazyItemViewProtocol> *)itemView mui_didEnterWithTimes:times];
                    }
                }
            }
            
            [_needReloadingMuiIDs removeObject:muiID];
        }
    }
    
    [_newVisibleMuiIDs removeObject:muiID];
    if (_newVisibleMuiIDs.count > 0) {
        if (isReload == YES || self.loadAllItemsImmediately == YES || hasLoadAnItem == NO) {
            [self generateItems:isReload];
        } else {
            [self performSelector:@selector(generateItems:) withObject:@(NO) afterDelay:0.0000001];
        }
    }
}

- (void)assembleSubviews:(BOOL)isReload minY:(CGFloat)minY maxY:(CGFloat)maxY
{
    // Calculate which item views should be shown.
    // Calculating will cost some time, so here is a buffer for reducing
    // times of calculating.
    NSSet<TMLazyItemModel *> *newVisibleModels = [_modelBucket showingModelsFrom:minY - LazyBufferHeight
                                                                              to:maxY + LazyBufferHeight];
    NSSet<NSString *> *newVisibleMuiIDs = [newVisibleModels valueForKey:@"muiID"];

    // Find if item views are in visible area.
    // Recycle invisible item views.
    [self recycleItems:isReload newVisibleMuiIDs:newVisibleMuiIDs];
    
    // Generate or reload visible item views.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(generateItems:) object:@(NO)];
    _newVisibleMuiIDs = [newVisibleMuiIDs mutableCopy];
    [self generateItems:isReload];
    
    // Calculate the inScreenVisibleModels.
    [_inScreenVisibleMuiIDs removeAllObjects];
    for (TMLazyItemModel *itemModel in newVisibleModels) {
        if (itemModel.top < maxY && itemModel.bottom > minY) {
            [_inScreenVisibleMuiIDs addObject:itemModel.muiID];
        }
    }
}

#pragma mark Reload

- (void)storeItemModelsFromIndex:(NSInteger)startIndex
{
    if (startIndex == 0) {
        _itemCount = 0;
        [_modelBucket clear];
    }
    if (self.dataSource) {
        _itemCount = [self.dataSource numberOfItemsInScrollView:self];
        for (NSInteger index = startIndex; index < _itemCount; index++) {
            TMLazyItemModel *itemModel = [self.dataSource scrollView:self itemModelAtIndex:index];
            if (itemModel.muiID.length == 0) {
                itemModel.muiID = [NSString stringWithFormat:@"%zd", index];
            }
            [_modelBucket addModel:itemModel];
        }
    }
}

- (void)reloadData
{
    [self storeItemModelsFromIndex:0];
    [self assembleSubviews:YES];
}

- (void)loadMoreData
{
    [self storeItemModelsFromIndex:_itemCount];
    [self assembleSubviews:NO];
}

- (UIView *)dequeueReusableItemWithIdentifier:(NSString *)identifier
{
    return [self dequeueReusableItemWithIdentifier:identifier muiID:nil];
}

- (UIView *)dequeueReusableItemWithIdentifier:(NSString *)identifier muiID:(NSString *)muiID
{
    UIView *result = nil;
    if (identifier && identifier.length > 0) {
        if (_currentReloadingMuiID) {
            for (UIView *item in _visibleItems) {
                if ([item.muiID isEqualToString:_currentReloadingMuiID]
                 && [item.reuseIdentifier isEqualToString:identifier]) {
                    result = item;
                    break;
                }
            }
        }
        if (result == nil) {
            result = [self.reusePool dequeueItemViewForReuseIdentifier:identifier andMuiID:muiID];
        }
        if (result) {
            if (self.autoClearGestures) {
                result.gestureRecognizers = nil;
            }
            if ([result respondsToSelector:@selector(mui_prepareForReuse)]) {
                [(UIView<TMLazyItemViewProtocol> *)result mui_prepareForReuse];
            }
        }
    }
    return result;
}

#pragma mark Clear & Reset

- (void)clearVisibleItems
{
    for (UIView *itemView in _visibleItems) {
        if (itemView.reuseIdentifier.length > 0) {
            itemView.hidden = YES;
            [self.reusePool addItemView:itemView forReuseIdentifier:itemView.reuseIdentifier];
        }
    }
    [_visibleItems removeAllObjects];
}

- (void)removeAllLayouts
{
    [self clearVisibleItems];
}

- (void)resetItemsEnterTimes
{
    [_enterTimesDict removeAllObjects];
}

- (void)resetViewEnterTimes
{
    [self resetItemsEnterTimes];
}

#pragma mark Private

- (BOOL)isMuiIdVisible:(NSString *)muiID
{
    for (UIView *itemView in _visibleItems) {
        if ([itemView.muiID isEqualToString:muiID]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isDataSourceValid:(id<TMLazyScrollViewDataSource>)dataSource
{
    return dataSource
        && [dataSource respondsToSelector:@selector(numberOfItemsInScrollView:)]
        && [dataSource respondsToSelector:@selector(scrollView:itemModelAtIndex:)]
        && [dataSource respondsToSelector:@selector(scrollView:itemByMuiID:)];
}

@end

//****************************************************************

@implementation TMLazyOuterScrollViewObserver

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == LazyObserverContext && [keyPath isEqualToString:@"contentOffset"] && _lazyScrollView) {
        [_lazyScrollView outerScrollViewDidScroll];
    }
}

@end
