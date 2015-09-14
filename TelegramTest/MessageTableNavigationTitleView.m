//
//  MessageTableNavigationTitleView.m
//  Messenger for Telegram
//
//  Created by Dmitry Kondratyev on 3/2/14.
//  Copyright (c) 2014 keepcoder. All rights reserved.
//

#import "MessageTableNavigationTitleView.h"
#import "TLEncryptedChat+Extensions.h"
#import "TGTimer.h"
#import "ImageUtils.h"
#import "TGAnimationBlockDelegate.h"
#import "TGTimerTarget.h"
#import "ITSwitch.h"
@interface MessageTableNavigationTitleView()<TMTextFieldDelegate, TMSearchTextFieldDelegate>
@property (nonatomic, strong) TMNameTextField *nameTextField;
@property (nonatomic, strong) TMStatusTextField *statusTextField;
@property (nonatomic, strong) NSMutableAttributedString *attributedString;

@property (nonatomic,strong) TMTextField *typingTextField;


@property (nonatomic,strong) TMView *container;

@property (nonatomic,strong) BTRButton *searchButton;

@property (nonatomic,strong) ITSwitch *discussionSwitch;


@end



@implementation MessageTableNavigationTitleView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        
        self.container = [[TMView alloc] initWithFrame:self.bounds];
        self.container.wantsLayer = YES;
        
        self.typingTextField = [TMTextField defaultTextField];
        
        self.typingTextField.fieldDelegate = self;
        
        self.nameTextField = [[TMNameTextField alloc] initWithFrame:NSMakeRect(0, 3, 0, 0)];
        [self.nameTextField setAlignment:NSCenterTextAlignment];
        [self.nameTextField setAutoresizingMask:NSViewWidthSizable];
        [self.nameTextField setFont:[NSFont fontWithName:@"HelveticaNeue" size:14]];
        [self.nameTextField setTextColor:NSColorFromRGB(0x222222)];
        [self.nameTextField setSelector:@selector(titleForMessage)];
        [self.nameTextField setEncryptedSelector:@selector(encryptedTitleForMessage)];
        [[self.nameTextField cell] setTruncatesLastVisibleLine:YES];
        [[self.nameTextField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
        [self.nameTextField setDrawsBackground:NO];
        [self.nameTextField setNameDelegate:self];
        [self.container addSubview:self.nameTextField];
    
        self.statusTextField = [[TMStatusTextField alloc] initWithFrame:NSMakeRect(0, 3, 0, 0)];
        [self.statusTextField setSelector:@selector(statusForMessagesHeaderView)];
        [self.statusTextField setAlignment:NSCenterTextAlignment];
        [self.statusTextField setStatusDelegate:self];
        [self.statusTextField setDrawsBackground:NO];
        
        [self.statusTextField setFont:TGSystemFont(12)];
        [self.statusTextField setTextColor:GRAY_TEXT_COLOR];
        
        //[self.statusTextField setBackgroundColor:NSColorFromRGB(0x000000)];
        
        [self.container addSubview:self.statusTextField];
        
        _searchButton = [[BTRButton alloc] initWithFrame:NSMakeRect(NSWidth(self.container.frame) - image_SearchMessages().size.width - 30, 0, image_SearchMessages().size.width +10, image_SearchMessages().size.height+10)];
        
        [_searchButton addBlock:^(BTRControlEvents events) {
            
            if(![[Telegram rightViewController].messagesViewController searchBoxIsVisible]) {
                [[Telegram rightViewController].messagesViewController showSearchBox];
            }
            
        } forControlEvents:BTRControlEventClick];
        
        [_searchButton setImage:image_SearchMessages() forControlState:BTRControlStateNormal];
        
        [_searchButton setToolTip:@"cmd+f"];
        
        [self.container addSubview:_searchButton];
        
        [self addSubview:self.container];
        
        _discussionSwitch = [[ITSwitch alloc] initWithFrame:NSMakeRect(0, 0, 19, 12)];
        
        _discussionSwitch.tintColor = BLUE_UI_COLOR;
        
        [_discussionSwitch setDidChangeHandler:^(BOOL res){
            
            [[Telegram rightViewController].messagesViewController showOrHideChannelDiscussion];
            
            
        }];
        
        [self.container addSubview:_discussionSwitch];
        
    }
    return self;
}




-(void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    
    [self buildForSize:newSize];
}

-(void)textFieldDidChange:(id)field {
   [self buildForSize:self.bounds.size];
}

- (void)setDialog:(TL_conversation *)dialog {
    self->_dialog = dialog;
    
    [_discussionSwitch setHidden:dialog.type != DialogTypeChannel || dialog.chat.isBroadcast];
    [_discussionSwitch setOn:NO];
    
    [_searchButton setHidden:self.dialog.type == DialogTypeChannel];
    
    
    [self.nameTextField updateWithConversation:self.dialog];

    [self.statusTextField updateWithConversation:self.dialog];

    

    
    [self sizeToFit];
}





- (void)buildForSize:(NSSize)size {
    
    [self.container setFrameSize:size];
        

    [self.nameTextField sizeToFit];
    
    [_nameTextField setCenteredXByView:_nameTextField.superview];
    [_nameTextField setFrameOrigin:NSMakePoint(NSMinX(_nameTextField.frame), self.bounds.size.height - self.nameTextField.bounds.size.height - 4)];
    

  //  [self.statusTextField setFrame:NSMakeRect(10, 9, self.bounds.size.width - 40, self.statusTextField.frame.size.height)];
    
    [self.statusTextField setFrameOrigin:NSMakePoint(NSMinX(self.statusTextField.frame), 5)];
    
    [_searchButton setFrameOrigin:NSMakePoint(NSWidth(self.container.frame) - NSWidth(_searchButton.frame) +5, 10)];
    
    
    [_discussionSwitch setCenteredXByView:_discussionSwitch.superview];
    
    
    
    if(!_discussionSwitch.isHidden)
    {
        [_statusTextField setStringValue:NSLocalizedString(@"Channel.showcomments", nil)];
        
        [self.statusTextField sizeToFit];
        
        [_discussionSwitch setFrameOrigin:NSMakePoint(NSMinX(_discussionSwitch.frame) - roundf(NSWidth(_statusTextField.frame)/2), 6)];
        
        [self.statusTextField setFrameOrigin:NSMakePoint(NSMaxX(self.discussionSwitch.frame), 5)];
        
    } else {
        [self.statusTextField sizeToFit];
        [self.statusTextField setCenteredXByView:self.statusTextField.superview];
    }
    
    
    
   
    
    

}

- (void) TMStatusTextFieldDidChanged:(TMStatusTextField *)textField {
    [self.statusTextField sizeToFit];
    [self buildForSize:self.bounds.size];
}

- (void) TMNameTextFieldDidChanged:(TMNameTextField *)textField {
    [self buildForSize:self.bounds.size];
}





- (void)mouseDown:(NSEvent *)theEvent {
    [super mouseDown:theEvent];
    
    if(self.tapBlock)
        self.tapBlock();
    
}

@end
