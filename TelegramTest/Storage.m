
//
//  Storage.m
//  TelegramTest
//
//  Created by keepcoder on 28.10.13.
//  Copyright (c) 2013 keepcoder. All rights reserved.
//

#import "Storage.h"
#import "TLPeer+Extensions.h"
#import "SSKeychain.h"
#import "SSKeychainQuery.h"
#import "Crypto.h"
#import "LoopingUtils.h"
#import "PreviewObject.h"
#import "HistoryFilter.h"

#import "TGHashContact.h"
#import "NSString+FindURLs.h"
#import "NSData+Extensions.h"
@implementation Storage


NSString *const ENCRYPTED_IMAGE_COLLECTION = @"encrypted_image_collection";
NSString *const ENCRYPTED_PARAMS_COLLECTION = @"encrypted_params_collection";
NSString *const STICKERS_COLLECTION = @"stickers_collection";
NSString *const SOCIAL_DESC_COLLECTION = @"social_desc_collection";
NSString *const REPLAY_COLLECTION = @"replay_collection";
NSString *const FILE_NAMES = @"file_names";
NSString *const ATTACHMENTS = @"attachments";
-(id)init {
    if(self = [super init]) {
    }
    return self;
}


+(Storage *)manager {
    
    static Storage *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[[self class] alloc] init];
        
        [TGDatabase setManager:instance];
    });
    
    return (Storage *) [TGDatabase manager];

}

+(YapDatabaseConnection *)yap {
    static YapDatabase *db;
    static dispatch_once_t yapToken;
    static YapDatabaseConnection *connection;
    dispatch_once(&yapToken, ^{
        db = [[YapDatabase alloc] initWithPath:[NSString stringWithFormat:@"%@/yap_store.db",[self path]]];
        connection = [db newConnection];
    });
    
    return connection;
}



static NSString *encryptionKey = @"";


+(void)dbSetKey:(NSString *)key {
    
    [Storage manager];
    
    encryptionKey = key;
}

+(void)dbRekey:(NSString *)rekey {
    
    [[Storage manager] dbRekey:encryptionKey];
    
}

-(void)dbRekey:(NSString *)rekey {
    
    [queue inDatabase:^(FMDatabase *db) {
        
        [db rekey:rekey];
        
    }];
}

static NSString *kEmoji = @"kEmojiNew";


+ (NSMutableArray *)emoji {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *array = [defaults objectForKey:kEmoji];
    return array ? [NSMutableArray arrayWithArray:array] : [NSMutableArray array];
}

+ (void)saveEmoji:(NSMutableArray *)emoji {
    if(!emoji)
        return;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:emoji forKey:kEmoji];
    [defaults synchronize];
}

static NSString *kInputTextForPeers = @"kInputTextForPeers";

+ (NSMutableDictionary *)inputTextForPeers {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *dictionary = [defaults objectForKey:kInputTextForPeers];
    return dictionary ? [NSMutableDictionary dictionaryWithDictionary:dictionary] : [NSMutableDictionary dictionary];
}

+ (void)saveInputTextForPeers:(NSMutableDictionary *)dictionary {
    if(!dictionary)
        return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:dictionary forKey:kInputTextForPeers];
    [defaults synchronize];
}




-(TGUpdateState *)updateState {
    
    __block TGUpdateState *state;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
    
        [db beginTransaction];
        FMResultSet *result = [db executeQuery:@"select * from update_state limit 1"];
        
        if([result next]) {
            state = [[TGUpdateState alloc] initWithPts:[result intForColumn:@"pts"] qts:[result intForColumn:@"qts"] date:[result intForColumn:@"date"] seq:[result intForColumn:@"seq"] pts_count:[result intForColumn:@"pts_count"]];
        }
        
        [db commit];
        
        [result close];
        
    }];
    
    return state;
}

-(void)saveUpdateState:(TGUpdateState *)state {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from update_state where 1=1"];
        
        [db executeUpdate:@"insert into update_state (pts, qts, date, seq,pts_count) values (?,?,?,?,?)",@(state.pts),@(state.qts),@(state.date),@(state.seq),@(state.pts_count)];
    }];
}


- (void)searchMessagesBySearchString:(NSString *)searchString offset:(int)offset completeHandler:(void (^)(NSInteger count, NSArray *messages))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        NSString *searchSql = [NSString stringWithFormat:@"SELECT serialized, message_text,flags FROM messages WHERE instr(message_text,'%@') > 0  order by date desc LIMIT 50 OFFSET %d",[searchString lowercaseString],offset];

        FMResultSet *results = [db executeQueryWithFormat:searchSql, nil];
        NSMutableArray *messages = [[NSMutableArray alloc] init];
        while ([results next]) {
            TL_localMessage *msg = [TLClassStore deserialize:[[results resultDictionary] objectForKey:@"serialized"]];
            
            if(msg.dstate == DeliveryStateNormal) {
                msg.flags = -1;
                msg.message = [results stringForColumn:@"message_text"];
                msg.flags = [results intForColumn:@"flags"];
                [messages addObject:msg];
            }
        }
        [results close];
        
        if(completeHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completeHandler(messages.count, messages);
            });
        }
    }];
}

- (void)findFileInfoByPathHash:(NSString *)pathHash completeHandler:(void (^)(BOOL result, id file))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {        
        FMResultSet *result = [db executeQuery:@"select serialized from files where hash = ?", pathHash];
        id file = nil;
        
        if([result next]) {
            file = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
        }
        [result close];
        
        if(completeHandler) {
            [[ASQueue mainQueue] dispatchOnQueue:^{
                completeHandler(file != nil, file);
            }];
        }
    }];
}


- (id)fileInfoByPathHash:(NSString *)pathHash  {
    
    __block id file;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        FMResultSet *result = [db executeQuery:@"select serialized from files where hash = ?", pathHash];
        
        if([result next]) {
            file = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
        }
        [result close];
    }];
    
    return file;
}

- (void)setFileInfo:(id)file forPathHash:(NSString *)pathHash {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into files (hash, serialized) values (?,?)", pathHash, [TLClassStore serialize:file isCacheSerialize:NO]];
    }];
}

- (void)deleteFileHash:(NSString *)pathHash {
    [queue inDatabase:^(FMDatabase *db) {
        
        [db executeUpdate:@"delete from files WHERE hash = ?",pathHash];
    }];
}

-(void)messages:(TLPeer *)peer max_id:(int)max_id limit:(int)limit next:(BOOL)next filterMask:(int)mask completeHandler:(void (^)(NSArray *))completeHandler {
    
    int peer_id = [peer peer_id];
    [queue inDatabase:^(FMDatabase *db) {
        
        NSString *tableName = @"messages";
        
        NSString *sql = [NSString stringWithFormat:@"select serialized,flags,message_text from %@ where destruct_time > %d and peer_id = %d and n_id %@ %d and (filter_mask & %d > 0) order by date %@ limit %d",tableName,[[MTNetwork instance] getTime],peer_id,(next && (max_id != 0 && max_id != INT32_MIN)) ? @"<" : @">",max_id,mask,next ? @"DESC" : @"ASC",limit];
        
        
        
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        __block NSMutableArray *messages = [[NSMutableArray alloc] init];
        while ([result next]) {
            TLMessage *msg = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            msg.flags = -1;
            msg.message = [result stringForColumn:@"message_text"];
            msg.flags = [result intForColumn:@"flags"];
            [messages addObject:msg];
        }
        [result close];
        
      
        
        
        [LoopingUtils runOnMainQueueAsync:^{
            if(completeHandler)
                completeHandler(messages);
        }];
        
    }];
}

-(void)loadMessages:(int)conversationId localMaxId:(int)localMaxId limit:(int)limit next:(BOOL)next maxDate:(int)maxDate filterMask:(int)mask completeHandler:(void (^)(NSArray *))completeHandler {
    
    
     __block NSMutableArray *messages = [[NSMutableArray alloc] init];
    
    
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        //718606
        int currentDate = maxDate;

                
        if(localMaxId != 0 && currentDate == 0) {
            FMResultSet *selectedMessageDateResult = [db executeQuery:@"SELECT date FROM messages WHERE n_id=?",@(localMaxId)];
            if([selectedMessageDateResult next])
                currentDate = [selectedMessageDateResult intForColumn:@"date"];
            
            [selectedMessageDateResult close];
            
            
            
            
        }
        
        
        if(currentDate == 0)
            currentDate = [[MTNetwork instance] getTime];
        
        NSString *sql = [NSString stringWithFormat:@"select serialized,flags,message_text from messages where destruct_time > %d and peer_id = %d and date %@ %d and (filter_mask & %d > 0) order by date %@, n_id %@ limit %d",[[MTNetwork instance] getTime],conversationId,next ? @"<=" : @">",currentDate,mask, next ? @"DESC" : @"ASC",next ? @"DESC" : @"ASC",limit];
        
        
        
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        
        
        while ([result next]) {
            TL_localMessage *msg = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            msg.flags = -1;
            msg.message = [result stringForColumn:@"message_text"];
            msg.flags = [result intForColumn:@"flags"];
            [messages addObject:msg];
        }
        [result close];
        
      //  test_step_group(@"history");
        
        TL_localMessage *lastMessage = [messages lastObject];
        
        if(lastMessage) {
            
            NSArray *selectedCount = [messages filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self.date == %d",lastMessage.date]];
           
            int localCount = [db intForQuery:@"SELECT count(*) from messages where date = ? and peer_id = ?",@(lastMessage.date),@(lastMessage.peer_id)];
            if(selectedCount.count < localCount) {
                
                NSString *sql = [NSString stringWithFormat:@"select serialized,flags,message_text from messages where date = %d and n_id != %d and peer_id = %d order by n_id desc",lastMessage.date,lastMessage.n_id,lastMessage.peer_id];
                
                 FMResultSet *result = [db executeQueryWithFormat:sql,nil];
                
                 while ([result next]) {
                    TL_localMessage *msg = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
                     msg.flags = -1;
                     msg.message = [result stringForColumn:@"message_text"];
                     msg.flags = [result intForColumn:@"flags"];
                     [messages addObject:msg];
                 }
                 [result close];
                
            }
        }
        
        
        
        
    }];
    
    
    NSArray *supportList = [messages filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self.reply_to_msg_id != 0"]];
    
    NSMutableArray *supportIds = [[NSMutableArray alloc] init];
    
    [supportList enumerateObjectsUsingBlock:^(TL_localMessage *obj, NSUInteger idx, BOOL *stop) {
        
        [supportIds addObject:@([obj reply_to_msg_id])];
        
    }];
    
    NSArray *support = [self selectSupportMessages:supportIds];
    
    [[MessagesManager sharedManager] addSupportMessages:support];
    
    if(completeHandler)
        completeHandler(messages);

}


-(TL_localMessage *)messageById:(int)msgId {
    __block TL_localMessage *message;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        NSString *sql = [NSString stringWithFormat:@"select serialized,flags,message_text from messages where n_id = %d",msgId];
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        while ([result next]) {
            message = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            message.flags = -1;
            message.message = [result stringForColumn:@"message_text"];
            message.flags = [result intForColumn:@"flags"];
        }
        [result close];

    }];
    
    return message;

}

-(void)messages:(void (^)(NSArray *))completeHandler forIds:(NSArray *)ids random:(BOOL)random  {
    
    [self messages:completeHandler forIds:ids random:random sync:NO];
}


-(void)messages:(void (^)(NSArray *))completeHandler forIds:(NSArray *)ids random:(BOOL)random sync:(BOOL)sync {
    
    void (^block)(FMDatabase *db) = ^(FMDatabase *db) {
        NSString *strIds = [ids componentsJoinedByString:@","];
        
        NSString *sql = [NSString stringWithFormat:@"select serialized,flags,message_text from messages where %@ in (%@) order by date DESC",random ? @"random_id" : @"n_id",strIds];
        
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        __block NSMutableArray *messages = [[NSMutableArray alloc] init];
        while ([result next]) {
            TLMessage *msg = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            msg.flags = -1;
            msg.message = [result stringForColumn:@"message_text"];
            msg.flags = [result intForColumn:@"flags"];
            [messages addObject:msg];
        }
        [result close];
        
        if(!sync) {
            [LoopingUtils runOnMainQueueAsync:^{
                if(completeHandler)
                    completeHandler(messages);
            }];
        } else {
            if(completeHandler)
                completeHandler(messages);
        }
       

    };
    
    if(sync) {
        [queue inDatabaseWithDealocing:block];
    } else {
        [queue inDatabase:block];
    }
    
  
}



-(void)lastMessageForPeer:(TLPeer *)peer completeHandler:(void (^)(TL_localMessage *message))completeHandler {
    
    int peer_id = [peer peer_id];
    [queue inDatabase:^(FMDatabase *db) {
        
        TL_localMessage *message;
        FMResultSet *result = [db executeQuery:@"select * from messages where peer_id = ? ORDER BY date DESC LIMIT 1",@(peer_id)];
        
        
        if([result next]) {
            int date = [result intForColumn:@"date"];
            
            [result close];
            
            
            result = [db executeQuery:@"select * from messages where peer_id = ? AND date = ? ORDER BY n_id DESC LIMIT 1",@(peer_id),@(date)];
            
            
            if([result next]) {
                message = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
                message.flags = -1;
                message.message = [result stringForColumn:@"message_text"];
                message.flags = [result intForColumn:@"flags"];
            }
            
        }
        
        
        
        
        
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler != nil) completeHandler(message);
        });
    }];

}


-(void)updateTopMessage:(TL_conversation *)dialog completeHandler:(void (^)(BOOL result))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"update dialogs set top_message = (?) where peer_id = ?",
            [NSNumber numberWithInt:dialog.top_message],
            [NSNumber numberWithInt:[[dialog peer] peer_id]]
         ];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(YES);
        });
    }];
}



-(void)updateMessages:(NSArray *)messages {
    [queue inDatabase:^(FMDatabase *db) {
        
        [messages enumerateObjectsUsingBlock:^(TL_localMessage *obj, NSUInteger idx, BOOL *stop) {
            
            int destructTime = INT32_MAX;
            
            if([obj isKindOfClass:[TL_destructMessage class]])
                destructTime = [(TL_destructMessage *)obj destruction_time];
            
             [db executeUpdate:@"update messages set message_text = ?, flags = ?, from_id = ?, peer_id = ?, date = ?, serialized = ?, random_id = ?, destruct_time = ?, filter_mask = ?, fake_id = ?, dstate = ? WHERE n_id = ?",obj.message,@(obj.flags),@(obj.from_id),@(obj.peer_id),@(obj.date),[TLClassStore serialize:obj],@(obj.randomId), @(destructTime), @(obj.filterType),@(obj.fakeId),@(obj.dstate),@(obj.n_id),nil];
            
        }];
    
    }];
}


-(void)insertMessage:(TLMessage *)message completeHandler:(dispatch_block_t)completeHandler {
    [self insertMessages:@[message] completeHandler:completeHandler];
}

-(void)markMessagesAsRead:(NSArray *)messages useRandomIds:(NSArray *)randomIds {
    
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        
        NSString *mark,*sql;
        
        if(messages.count > 0) {
            mark = [messages componentsJoinedByString:@","];
            sql = [NSString stringWithFormat:@"update messages set flags = flags & ~1 WHERE n_id IN (%@)",mark];
            [db executeUpdateWithFormat:sql,nil];
        }
        
        if(randomIds.count > 0) {
            mark = [randomIds componentsJoinedByString:@","];
            sql = [NSString stringWithFormat:@"update messages set flags = flags & ~1 WHERE random_id IN (%@)",mark];
            [db executeUpdateWithFormat:sql,nil];
        }
    
    }];
}

-(void)markAllInDialog:(TL_conversation *)dialog {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"update messages set flags= flags & ~1 where peer_id = ?",[NSNumber numberWithInt:dialog.peer.peer_id]];
        //[db commit];

    }];
}

-(NSArray *)markAllInConversation:(TL_conversation *)conversation max_id:(int)max_id {
    
    NSMutableArray *ids = [[NSMutableArray alloc] init];
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        //[db beginTransaction];
        
        FMResultSet *result = [db executeQuery:@"select n_id from messages where flags & 1 = 1 and peer_id = ? and n_id <= ?",@(conversation.peer.peer_id),@(max_id)];
        
        
        
        while ([result next]) {
            
            [ids addObject:@([result intForColumn:@"n_id"])];
        }
        
        [db executeUpdate:@"update messages set flags= flags & ~1 where peer_id = ? and n_id <= ?",@(conversation.peer.peer_id),@(max_id)];
        //[db commit];
        
    }];
    
    return ids;
}

-(void)readMessagesContent:(NSArray *)messages {
    [queue inDatabase:^(FMDatabase *db) {
        NSString *mark = [messages componentsJoinedByString:@","];
        NSString *sql = [NSString stringWithFormat:@"update messages set flags = flags & ~32 WHERE n_id IN (%@)",mark];
        [db executeUpdateWithFormat:sql,nil];
        
    }];
}


-(void)deleteMessagesWithRandomIds:(NSArray *)messages completeHandler:(void (^)(BOOL result))completeHandler; {
    [queue inDatabase:^(FMDatabase *db) {
        NSString *mark = [messages componentsJoinedByString:@","];
        
        
        
        NSString *sql = [NSString stringWithFormat:@"select n_id from messages where random_id IN (%@)",mark];
        
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        
        NSMutableArray *ids = [[NSMutableArray alloc] init];
        
        while ([result next]) {
            
            [ids addObject:@([result intForColumn:@"n_id"])];
        }
        
        [result close];
        
        NSString *sids = [ids componentsJoinedByString:@","];
        
        
        sql = [NSString stringWithFormat:@"delete from messages WHERE n_id IN (%@)",sids];
        [db executeUpdateWithFormat:sql,nil];
        
        sql = [NSString stringWithFormat:@"delete from sharedmedia WHERE message_id IN (%@)",sids];
        [db executeUpdateWithFormat:sql,nil];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(YES);
        });
        
    }];
}

-(void)deleteMessages:(NSArray *)messages completeHandler:(void (^)(BOOL result))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        NSString *mark = [messages componentsJoinedByString:@","];
        
        NSString *sql = [NSString stringWithFormat:@"delete from messages WHERE n_id IN (%@)",mark];
        [db executeUpdateWithFormat:sql,nil];
        
        sql = [NSString stringWithFormat:@"delete from sharedmedia WHERE message_id IN (%@)",mark];
        [db executeUpdateWithFormat:sql,nil];
        
        
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(YES);
        });
    }];
}

-(void)deleteMessagesInDialog:(TL_conversation *)dialog completeHandler:(dispatch_block_t)completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        [db beginTransaction];
        NSString *sql = [NSString stringWithFormat:@"delete from messages WHERE peer_id = %d",dialog.peer.peer_id];
        [db executeUpdateWithFormat:sql,nil];
        
        sql = [NSString stringWithFormat:@"delete from sharedmedia WHERE peer_id  =%d",dialog.peer.peer_id];
        [db executeUpdateWithFormat:sql,nil];
        
        
        if(dialog.type == DialogTypeSecretChat)
            [db executeUpdate:@"delete from self_destruction where chat_id = ?",[NSNumber numberWithInt:dialog.peer.chat_id]];
        [db commit];
        
        if(completeHandler)
            dispatch_async(dispatch_get_main_queue(), ^{
                completeHandler();
            });
    }];
}

-(void)insertMessages:(NSArray *)messages completeHandler:(dispatch_block_t)completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
         //[db beginTransaction];
        NSArray *msgs = [messages copy];
        for (TL_localMessage *message in msgs) {
            
            TL_localMessage *m = [message copy];
            m.message = @"";
            
            int destruct_time = INT32_MAX;
            if([message isKindOfClass:[TL_destructMessage class]]) {
                if(((TL_destructMessage *)message).destruction_time != 0)
                    destruct_time = ((TL_destructMessage *)message).destruction_time;
            }
            int peer_id = [message peer_id];
            
            int mask = message.filterType;
            
            
            void (^insertBlock)(NSString *tableName) = ^(NSString *tableName) {
                
                [db executeUpdate:[NSString stringWithFormat:@"insert or replace into %@ (n_id,date,from_id,flags,peer_id,serialized, destruct_time, message_text, filter_mask,fake_id,dstate,random_id) values (?,?,?,?,?,?,?,?,?,?,?,?)",tableName],
                 @(message.n_id),
                 @(message.date),
                 @(message.from_id),
                 @(message.flags),
                 @(peer_id),
                 [TLClassStore serialize:m],
                 @(destruct_time),
                 message.message,
                 @(mask),
                 @(message.fakeId),
                 @(message.dstate),
                 @(message.randomId)
                 ];

            };
            
            
            if(message.n_id < TGMINFAKEID) {
                
                NSString *sql = [NSString stringWithFormat:@"delete from messages WHERE n_id = %d",message.fakeId];
                [db executeUpdateWithFormat:sql,nil];
                
            }
           
           insertBlock(@"messages");
            
            if([message.media isKindOfClass:[TL_messageMediaEmpty class]]) {
                [Telegram saveHashTags:message.message peer_id:message.peer_id];
                
            }
            
            
            
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler();
        });
    }];
}



-(void)executeSaveConversation:(TL_conversation *)dialog  db:(FMDatabase *)db {
    
    if(!dialog.isAddToList) {
        return;
    }
    
   
    
    [db executeUpdate:@"insert or replace into dialogs (peer_id,top_message,last_message_date,unread_count,type,notify_settings,last_marked_message,sync_message_id,last_marked_date,last_real_message_date) values (?,?,?,?,?,?,?,?,?,?)",
     @([dialog.peer peer_id]),
     @(dialog.top_message),
     @(dialog.last_message_date),
     @(dialog.unread_count),
     @(dialog.type),
     [TLClassStore serialize:dialog.notify_settings],
     @(dialog.last_marked_message),
     @(dialog.sync_message_id),
     @(dialog.last_marked_date),
     @(dialog.last_real_message_date)
     ];
}


- (void)updateDialog:(TL_conversation *)dialog {
    
    
    [queue inDatabase:^(FMDatabase *db) {
        [self executeSaveConversation:dialog db:db];
    }];
}


-(void)loadChats:(void (^)(NSArray *chats))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
         NSMutableArray *chats = [[NSMutableArray alloc] init];
        FMResultSet *secretResult = [db executeQuery:@"select * from encrypted_chats"];
        while ([secretResult next]) {
            [chats addObject:[TLClassStore deserialize:[secretResult dataForColumn:@"serialized"]]];
        }
        [secretResult close];
        
        
        FMResultSet *chatResult = [db executeQuery:@"select * from chats"];
        while ([chatResult next]) {
            [chats addObject:[TLClassStore deserialize:[chatResult dataForColumn:@"serialized"]]];
        }
        
        [chatResult close];
        
         if(completeHandler)
                completeHandler(chats);
    }];
}

- (void)parseDialogs:(FMResultSet *)result dialogs:(NSMutableArray *)dialogs messages:(NSMutableArray *)messages {
    while ([result next]) {
        
        
        TL_conversation *dialog = [[TL_conversation alloc] init];
        int type = [result intForColumn:@"type"];
        
        if(type == DialogTypeSecretChat) {
            dialog.peer = [TL_peerSecret createWithChat_id:[result intForColumn:@"peer_id"]];
        } else if(type == DialogTypeUser) {
            dialog.peer = [TL_peerUser createWithUser_id:[result intForColumn:@"peer_id"]];
        } else if(type == DialogTypeChat) {
            dialog.peer = [TL_peerChat createWithChat_id:-[result intForColumn:@"peer_id"]];
        } else if(type == DialogTypeBroadcast) {
            dialog.peer = [TL_peerBroadcast createWithChat_id:[result intForColumn:@"peer_id"]];
        }
        
        
        id notifyObject = [result dataForColumn:@"notify_settings"];
        
        if(notifyObject != nil && ![notifyObject isKindOfClass:[NSNull class]]) {
            dialog.notify_settings = [TLClassStore deserialize:notifyObject];
        }
        
        dialog.unread_count = [result intForColumn:@"unread_count"];
        dialog.top_message = [result intForColumn:@"top_message"];
        dialog.last_message_date = [result intForColumn:@"last_message_date"];
        dialog.last_marked_message = [result intForColumn:@"last_marked_message"];
        dialog.last_marked_date = [result intForColumn:@"last_marked_date"];
        dialog.sync_message_id = [result intForColumn:@"sync_message_id"];
        dialog.last_real_message_date = [result intForColumn:@"last_real_message_date"];
        
        id serializedMessage =[[result resultDictionary] objectForKey:@"serialized_message"];
        TL_localMessage *message;
        if(![serializedMessage isKindOfClass:[NSNull class]]) {
            message = [TLClassStore deserialize:serializedMessage];
            message.flags = -1;
            message.message = [result stringForColumn:@"message_text"];
            message.flags = [result intForColumn:@"flags"];
            if(message)
                [messages addObject:message];
        }
        
        dialog.lastMessage = message;
        
        [dialogs addObject:dialog];
    }
}

- (void)dialogByPeer:(int)peer completeHandler:(void (^)(TLDialog *dialog, TLMessage *message))completeHandler {
    [self searchDialogsByPeers:[NSArray arrayWithObject:@(peer)] needMessages:NO searchString:nil completeHandler:^(NSArray *dialogs, NSArray *messages, NSArray *searchMessages) {
        
        if(completeHandler) {
            completeHandler(dialogs.count ? dialogs[0] : nil, messages.count ? messages[0] : nil);
        }
        
    }];
}

- (void)searchDialogsByPeers:(NSArray *)peers needMessages:(BOOL)needMessages searchString:(NSString *)searchString completeHandler:(void (^)(NSArray *dialogs, NSArray *messages, NSArray *searchMessages))completeHandler {
    
    NSMutableArray *dialogs = [[NSMutableArray alloc] init];
    NSMutableArray *messages = [[NSMutableArray alloc] init];
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        if(peers.count) {
            FMResultSet *result = [db executeQuery:[NSString stringWithFormat:@"select messages.message_text,messages.from_id, dialogs.peer_id, dialogs.type,dialogs.last_message_date, messages.serialized serialized_message, dialogs.top_message,dialogs.sync_message_id,dialogs.last_marked_date,dialogs.unread_count unread_count, dialogs.notify_settings notify_settings, dialogs.last_marked_message last_marked_message,dialogs.last_real_message_date last_real_message_date, messages.flags from dialogs left join messages on dialogs.top_message = messages.n_id where dialogs.peer_id in (%@) ORDER BY dialogs.last_message_date DESC", [peers componentsJoinedByString:@","]]];
            
            
            [self parseDialogs:result dialogs:dialogs messages:messages];
            
            [result close];
        }
        
    }];
    
    if(completeHandler) {
        //   [[ASQueue mainQueue] dispatchOnQueue:^{
        completeHandler(dialogs, messages, nil);
        // }];
    }
    
}

-(void)dialogsWithOffset:(int)offset limit:(int)limit completeHandler:(void (^)(NSArray *d, NSArray *m))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *dialogs = [[NSMutableArray alloc] init];
        NSMutableArray *messages = [[NSMutableArray alloc] init];
        
        
        FMResultSet *result = [db executeQuery:@"select messages.message_text,messages.from_id, dialogs.peer_id, dialogs.type,dialogs.last_message_date, messages.serialized serialized_message, dialogs.top_message,dialogs.sync_message_id,dialogs.last_marked_date,dialogs.unread_count unread_count, dialogs.notify_settings notify_settings, dialogs.last_marked_message last_marked_message,dialogs.last_real_message_date last_real_message_date, messages.flags from dialogs left join messages on dialogs.top_message = messages.n_id ORDER BY dialogs.last_real_message_date DESC LIMIT ? OFFSET ?",[NSNumber numberWithInt:limit],[NSNumber numberWithInt:offset]];
        
        [self parseDialogs:result dialogs:dialogs messages:messages];
        
        [result close];
        
        if(completeHandler) completeHandler(dialogs,messages);
    }];
}




-(void)insertDialogs:(NSArray *)dialogs completeHandler:(void (^)(BOOL))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        [db beginTransaction];
        for (TL_conversation *dialog in dialogs) {
            [self executeSaveConversation:dialog db:db];
        }
        [db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(YES);
        });
        
    }];
}


-(void)insertChat:(TLChat *)chat completeHandler:(void (^)(BOOL))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        BOOL result = [db executeUpdate:@"insert or replace into chats (n_id,serialized) values (?,?)",[NSNumber numberWithInt:chat.n_id], [TLClassStore serialize:chat]];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(result);
        });
    }];
}



-(void)deleteDialog:(TL_conversation *)dialog completeHandler:(void (^)(void))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        [db beginTransaction];
        [db executeUpdate:@"delete from dialogs where peer_id = ?",[NSNumber numberWithInt:dialog.peer.peer_id]];
        [db executeUpdate:@"delete from messages where peer_id = ?",[NSNumber numberWithInt:dialog.peer.peer_id]];
        [db executeUpdate:@"delete from sharedmedia where peer_id = ?",[NSNumber numberWithInt:dialog.peer.peer_id]];
        if([dialog.peer isChat]) {
            [db executeUpdate:@"delete from encrypted_chats where chat_id = ?",[NSNumber numberWithInt:dialog.peer.chat_id]];
            [db executeUpdate:@"delete from chats where n_id = ?",[NSNumber numberWithInt:dialog.peer.chat_id]];
            if(dialog.type == DialogTypeSecretChat)
                [db executeUpdate:@"delete from self_destruction where chat_id = ?",[NSNumber numberWithInt:dialog.peer.chat_id]];
            
            if(dialog.type == DialogTypeBroadcast) {
                [db executeUpdate:@"delete from broadcasts where n_id = ?",@(dialog.peer.chat_id)];
            }
        }
        
        
        
        [db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler();
        });
        
    }];
}


-(void)insertChats:(NSArray *)chats completeHandler:(void (^)(BOOL))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        __block BOOL result;
        //[db beginTransaction];
        for (TLChat *chat in chats) {
            result = [db executeUpdate:@"insert or replace into chats (n_id,serialized) values (?,?)",[NSNumber numberWithInt:chat.n_id], [TLClassStore serialize:chat]];
        }
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(result);
        });
        
    }];
}


-(void)chats:(void (^)(NSArray *))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *chats = [[NSMutableArray alloc] init];
        //[db beginTransaction];
      FMResultSet *result = [db executeQuery:@"select * from chats"];
        while ([result next]) {
            TLChat *chat = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
            [chats addObject:chat];
        }
        [result close];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(chats);
        });
    }];
}

-(void)users:(void (^)(NSArray *))completeHandler {
    
    
    [queue inDatabase:^(FMDatabase *db) {

        NSMutableArray *users = [[NSMutableArray alloc] init];
        
        FMResultSet *result = [db executeQuery:@"select * from users"];
        
        while ([result next]) {
            TLUser *user = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            user.lastSeenUpdate = [result intForColumn:@"lastseen_update"];
            [users addObject:user];
        }
        
        
        [result close];
        
        if(completeHandler) {
            completeHandler(users);
        }
    }];
}



- (void)insertUser:(TLUser *)user completeHandler:(void (^)(BOOL result))completeHandler {
    [self insertUsers:@[user] completeHandler:completeHandler];
}

- (void)insertUsers:(NSArray *)users completeHandler:(void (^)(BOOL result))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        for (TLUser *user in users) {
            
            if([user isKindOfClass:[TL_userSelf class]]) {
                [[NSUserDefaults standardUserDefaults] setObject:[TLClassStore serialize:user] forKey:@"selfUser"];
            }
            
            [db executeUpdate:@"insert or replace into users (n_id, serialized,lastseen_update) values (?,?,?)", @(user.n_id), [TLClassStore serialize:user],@(user.lastSeenUpdate)];
        }
        
        if(completeHandler) {
            [[ASQueue mainQueue] dispatchOnQueue:^{
                completeHandler(YES);
            }];
        }
    }];
}




- (void) insertContact:(TLContact *) contact completeHandler:(void (^)(void))completeHandler {
    
    
    [queue inDatabase:^(FMDatabase *db) {
        if(![db executeUpdate:@"insert or replace into contacts (user_id, mutual) values (?,?)", [NSNumber numberWithInt:contact.user_id],[NSNumber numberWithBool:contact.mutual]]) {
            ELog(@"DB insert contact error: %d", contact.user_id);
        }
        [LoopingUtils runOnMainQueueAsync:^{
            if(completeHandler)
                completeHandler();
        }];
    }];
}

- (void) removeContact:(TLContact *) contact {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from contacts where user_id = ?", [NSNumber numberWithInt:contact.user_id]];
        
    }];
}


- (void) insertContact:(TLContact *) contact {
    [self insertContacst:@[contact]];
}

-(void)insertContacst:(NSArray *)contacts  {
    
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        for (TLContact *contact in contacts) {
            [db executeUpdate:@"insert or replace into contacts (user_id,mutual) values (?,?)",[NSNumber numberWithInt:contact.user_id],[NSNumber numberWithBool:contact.mutual]];
        }
        //[db commit];
    }];
}


-(void)dropContacts {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"delete from contacts where 1 = 1"];
        //[db commit];
        
    }];
}


-(void)contacts:(void (^)(NSArray *))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *contacts = [[NSMutableArray alloc] init];
        FMResultSet *result = [db executeQuery:@"select * from contacts"];
        while ([result next]) {
            TLContact *contact = [[TLContact alloc] init];
            contact.user_id = [[[result resultDictionary] objectForKey:@"user_id"] intValue];
            contact.mutual = [[[result resultDictionary] objectForKey:@"mutual"] boolValue];
            [contacts addObject:contact];
        }
        [result close];
            if(completeHandler)
                completeHandler(contacts);
    }];
}

-(void)insertSession:(NSData *)session completeHandler:(void (^)(void))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"insert or replace into sessions (session) values (?)",session];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler();
        });
    }];
}

-(void)sessions:(void (^)(NSArray *))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *sessions = [[NSMutableArray alloc] init];
        //[db beginTransaction];
        FMResultSet *result = [db executeQuery:@"select * from sessions"];
        while ([result next]) {
            [sessions addObject:[[result resultDictionary] objectForKey:@"session"]];
        }
        [result close];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(sessions);
        });
    }];
}

-(void)destroySessions {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from sessions where 1 = 1"];
    }];
}





-(void)fullChats:(void (^)(NSArray *chats))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *chats = [[NSMutableArray alloc] init];
        //[db beginTransaction];
        FMResultSet *result = [db executeQuery:@"select * from chats_full_new"];
        while ([result next]) {
            TLChatFull *fullChat = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
            [chats addObject:fullChat];
        }
        [result close];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(chats);
        });
    }];

}

-(void)insertFullChat:(TLChatFull *)fullChat completeHandler:(void (^)(void))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into chats_full_new (n_id, last_update_time, serialized) values (?,?,?)",@(fullChat.n_id), @([[MTNetwork instance] getTime]), [TLClassStore serialize:fullChat]];
        //[db commit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler();
        });
    }];
}

-(void)chatFull:(int)n_id completeHandler:(void (^)(TLChatFull *chat))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        FMResultSet *result = [db executeQuery:@"select * from chats_full where n_id = ?",[NSNumber numberWithInt:n_id]];
        [result next];
        if([result resultDictionary]) {
             TLChatFull *fullChat = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
            dispatch_async(dispatch_get_main_queue(), ^{
                if(completeHandler) completeHandler(fullChat);
            });
        }
        [result close];
        //[db commit];
        
    }];
}

-(void)insertImportedContacts:(NSSet *)result {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
       [result enumerateObjectsUsingBlock:^(TGHashContact *contact, BOOL *stop) {
           [db executeUpdate:@"insert or replace into imported_contacts (hash,hashObject,user_id) values (?,?,?)",@(contact.hash),contact.hashObject,@(contact.user_id)];
       }];
        
    }];
}

-(void)deleteImportedContacts:(NSSet *)result {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [result enumerateObjectsUsingBlock:^(TGHashContact *contact, BOOL *stop) {
            [db executeUpdate:@"delete from imported_contacts where hash = ?",@(contact.hash)];
        }];
        
        //[db commit];
    }];
}

-(void)importedContacts:(void (^)(NSSet *imported))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableSet *contacts = [[NSMutableSet alloc] init];
        //[db beginTransaction];
        FMResultSet *result = [db executeQuery:@"select * from imported_contacts"];
        while ([result next]) {
            
           
            TGHashContact *contact = [[TGHashContact alloc] initWithHash:[result stringForColumn:@"hashObject"] user_id:[result intForColumn:@"user_id"]];
            
            [contacts addObject:contact];
            
            
        }
        [result close];
        //[db commit];
        if(completeHandler) completeHandler(contacts);
    }];

}

-(void)unreadCount:(void (^)(int count))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        
        FMResultSet *result = [db executeQuery:@"select sum(unread_count) AS unread_count from dialogs"];
       
        
        int unread_count  = -1;
        while ([result next]) {
            unread_count = [result intForColumn:@"unread_count"];
        }
        
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(unread_count);
        });
        [result close];
    }];

}


-(void)insertEncryptedChat:(TL_encryptedChat *)chat {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"insert or replace into encrypted_chats (chat_id,serialized) values (?,?)",[NSNumber numberWithInt:chat.n_id],[TLClassStore serialize:chat]];
        //[db commit];
    }];
}


-(void)insertMedia:(TL_localMessage *)message {
    [queue inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"insert or replace into sharedmedia (message_id,peer_id,serialized,date,filter_mask) values (?,?,?,?,?)",@(message.n_id),@(message.peer_id),[TLClassStore serialize:message],@([[MTNetwork instance] getTime]),@(message.filterType)];
    }];
}


-(void)countOfUserPhotos:(int)user_id {
    __block int count = 0;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        count = [db intForQuery:@"select count(*) from user_photos where user_id = ?",@(user_id)];
        
    }];
}

-(void)addUserPhoto:(int)user_id media:(TLUserProfilePhoto *)photo {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into user_photos (id,user_id,serialized,date) values (?,?,?,?)",@(photo.photo_id),@(user_id),[TLClassStore serialize:photo],@([[MTNetwork instance] getTime])];
    }];
}

-(void)deleteUserPhoto:(int)n_id {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from user_photos where id = ? ",@(n_id)];
    }];
}


-(void)media:(void (^)(NSArray *))completeHandler max_id:(long)max_id peer_id:(int)peer_id next:(BOOL)next limit:(int)limit {
     [queue inDatabase:^(FMDatabase *db) {
         
         NSString *sql = [NSString stringWithFormat:@"select serialized,message_id from sharedmedia where peer_id = %d and message_id %@ %ld order by message_id DESC LIMIT %d",peer_id,next ? @"<" : @">",max_id,limit];

         FMResultSet *result = [db executeQueryWithFormat:sql,nil];
         __block NSMutableArray *list = [[NSMutableArray alloc] init];
         while ([result next]) {
             TL_localMessage *message = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
            
             
            [list addObject:[[PreviewObject alloc] initWithMsdId:[result intForColumn:@"message_id"] media:message peer_id:peer_id]];
         }
         
         [LoopingUtils  runOnMainQueueAsync:^{
            if(completeHandler)
                completeHandler(list);
        }];
     }];
}

-(int)countOfMedia:(int)peer_id {
    
    __block int count = 0;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
         count = [db intForQuery:@"select count(*) from sharedmedia where (filter_mask & 8 = 8) and peer_id = ?",@(peer_id)];
        
    }];
    
    return count;
}

-(void)pictures:(void (^)(NSArray *))completeHandler forUserId:(int)user_id {
    [queue inDatabase:^(FMDatabase *db) {
        
        NSString *sql = [NSString stringWithFormat:@"select serialized,id from user_photos where user_id = %d order by id DESC",user_id];
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        __block NSMutableArray *list = [[NSMutableArray alloc] init];
        while ([result next]) {
            TLUserProfilePhoto *photo = [TLClassStore deserialize:[[result resultDictionary] objectForKey:@"serialized"]];
            
             [list addObject:[[PreviewObject alloc] initWithMsdId:[result intForColumn:@"id"] media:photo peer_id:user_id]];
        }
        
        [LoopingUtils  runOnMainQueueAsync:^{
            if(completeHandler)
                completeHandler(list);
        }];
    }];
}


-(void)insertDestructor:(Destructor *)destructor {
    [queue inDatabase:^(FMDatabase *db) {
        //[db beginTransaction];
        [db executeUpdate:@"insert or replace into self_destruction (chat_id, max_id, ttl) values (?,?,?)",@(destructor.chat_id),@(destructor.max_id),@(destructor.ttl)];
        //[db commit];
    }];
}



-(void)selfDestructorFor:(int)chat_id max_id:(int)max_id completeHandler:(void (^)(Destructor *destructor))completeHandler {
    
    [queue inDatabase:^(FMDatabase *db) {
        FMResultSet *result = [db executeQuery:@"select * from self_destruction where chat_id = ? and max_id <= ? order by max_id desc limit 1",@(chat_id),@(max_id)];
        Destructor *destructor;
        while ([result next]) {
            destructor = [[Destructor alloc] initWithTLL:[result intForColumn:@"ttl"] max_id:[result intForColumn:@"max_id"] chat_id:[result intForColumn:@"chat_id"]];
        }
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(destructor);
        });
    }];
}

-(void)selfDestructors:(int)chat_id completeHandler:(void (^)(NSArray *destructors))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *destructors = [[NSMutableArray alloc] init];
        
        FMResultSet *result = [db executeQuery:@"select * from self_destruction where chat_id = ? order by max_id desc",@(chat_id)];
        
        while ([result next]) {
            Destructor * destructor = [[Destructor alloc] initWithTLL:[result intForColumn:@"ttl"] max_id:[result intForColumn:@"max_id"] chat_id:[result intForColumn:@"chat_id"]];
            [destructors addObject:destructor];
        }
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(destructors);
        });
    }];
}

-(void)selfDestructors:(void (^)(NSArray *destructors))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *destructors = [[NSMutableArray alloc] init];
        
        FMResultSet *result = [db executeQuery:@"select * from self_destruction order by max_id desc"];
        
        while ([result next]) {
            Destructor * destructor = [[Destructor alloc] initWithTLL:[result intForColumn:@"ttl"] max_id:[result intForColumn:@"max_id"] chat_id:[result intForColumn:@"chat_id"]];
            [destructors addObject:destructor];
        }
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(destructors);
        });
    }];
}

-(void)updateDestructTime:(int)time forMessages:(NSArray *)msgIds {
    [queue inDatabase:^(FMDatabase *db) {
        
        //[db beginTransaction];
        NSString *mark = [msgIds componentsJoinedByString:@","];
        NSString *sql = [NSString stringWithFormat:@"update messages set destruction_time = %d WHERE n_id IN (%@)",time,mark];
        [db executeUpdateWithFormat:sql,nil];

        //[db commit];
    }];
}


-(void)insertBlockedUsers:(NSArray *)users {
    [queue inDatabase:^(FMDatabase *db) {
        
        for (TL_contactBlocked *user in users) {
            [db executeUpdate:@"insert or replace into blocked_users (user_id, date) values (?,?)", @(user.user_id),@(user.date)];
        }
        
    }];
}

-(void)deleteBlockedUsers:(NSArray *)users {
    [queue inDatabase:^(FMDatabase *db) {
        
        NSMutableString *whereIn = [[NSMutableString alloc] init];
        
        for (TL_contactBlocked *user in users) {
            [whereIn appendFormat:@"%d,",user.user_id];
        }
         
       NSString *sql = [NSString stringWithFormat:@"delete from blocked_users WHERE user_id IN (%@)",[whereIn substringWithRange:NSMakeRange(0, whereIn.length-1)]];
        [db executeUpdateWithFormat:sql,nil];
        
    }];
}

-(void)blockedList:(void (^)(NSArray *users))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *contacs = [[NSMutableArray alloc] init];
        
        FMResultSet *result = [db executeQuery:@"select * from blocked_users"];
        
        while ([result next]) {
            TL_contactBlocked * contact = [TL_contactBlocked createWithUser_id:[result intForColumn:@"user_id"] date:[result intForColumn:@"date"]];
            [contacs addObject:contact];
        }
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(contacs);
        });
    }];

}



-(void)insertTask:(id<ITaskRequest>)task {
    [queue inDatabase:^(FMDatabase *db) {
        NSDictionary *params = [[task params] mutableCopy];
        
        NSMutableDictionary *accepted = [[NSMutableDictionary alloc] init];
        
        for (NSString *key in params.allKeys) {
            id tl = [params objectForKey:key];
            
            id serialized = [TLClassStore serialize:tl];
            
            if(serialized) {
                accepted[key] = serialized;
            }
        }
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:accepted];
        
        [db executeUpdate:@"insert or replace into tasks (task_id, params,extender) values (?,?,?)",@([task taskId]),data,NSStringFromClass([task class])];
    }];
}

-(void)removeTask:(id<ITaskRequest>)task {
    [queue inDatabase:^(FMDatabase *db) {
         [db executeUpdate:@"delete from tasks where task_id = ?",@([task taskId])];
    }];
}

-(void)selectTasks:(void (^)(NSArray *tasks))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *tasks = [[NSMutableArray alloc] init];
        FMResultSet *result = [db executeQuery:@"select * from tasks"];
        
        while ([result next]) {
            
            Class class = NSClassFromString([result stringForColumn:@"extender"]);
            
            NSDictionary *params = [NSKeyedUnarchiver unarchiveObjectWithData:[result dataForColumn:@"params"]];
            NSMutableDictionary *accepted = [[NSMutableDictionary alloc] init];
            
            for (NSString *key in params.allKeys) {
                id tl = [TLClassStore deserialize:params[key]];
                
                if(tl)
                    accepted[key] = tl;
                
                
            }
            
            NSUInteger taskId = [result intForColumn:@"task_id"];
            
            id <ITaskRequest> task = [[class alloc] initWithParams:accepted taskId:taskId];
            
            [tasks addObject:task];
        }
        [result close];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(completeHandler) completeHandler(tasks);
        });


    }];
}

-(TL_conversation *)selectConversation:(TLPeer *)peer {
    __block TL_conversation *conversation;
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        
        FMResultSet *result = [db executeQuery:@"select * from dialogs where peer_id = ?",@(peer.peer_id)];
        while ([result next]) {
            
            
            conversation = [[TL_conversation alloc] init];
            int type = [result intForColumn:@"type"];
            
            if(type == DialogTypeSecretChat) {
                conversation.peer = [TL_peerSecret createWithChat_id:[result intForColumn:@"peer_id"]];
            } else if(type == DialogTypeUser) {
                conversation.peer = [TL_peerUser createWithUser_id:[result intForColumn:@"peer_id"]];
            } else if(type == DialogTypeChat) {
                conversation.peer = [TL_peerChat createWithChat_id:-[result intForColumn:@"peer_id"]];
            } else if(type == DialogTypeBroadcast) {
                conversation.peer = [TL_peerBroadcast createWithChat_id:[result intForColumn:@"peer_id"]];
            }
            
            id notifyObject = [result dataForColumn:@"notify_settings"];
            
            if(notifyObject != nil && ![notifyObject isKindOfClass:[NSNull class]]) {
                conversation.notify_settings = [TLClassStore deserialize:notifyObject];
            }
            
            
            conversation.unread_count = [result intForColumn:@"unread_count"];
            conversation.top_message = [result intForColumn:@"top_message"];
            conversation.last_message_date = [result intForColumn:@"last_message_date"];
            conversation.last_marked_message = [result intForColumn:@"last_marked_message"];
            conversation.last_marked_date = [result intForColumn:@"last_marked_date"];

        }
        [result close];
        
    }];
    
    
    return conversation;

}




-(void)insertBroadcast:(TL_broadcast *)broadcast {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into broadcasts (n_id, serialized, title,date) values (?,?,?,?)",@(broadcast.n_id),[TLClassStore serialize:broadcast],broadcast.title,@(broadcast.date)];
    }];
}

-(void)deleteBroadcast:(TL_broadcast *)broadcast {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from broadcasts where n_id = ?",@(broadcast.n_id)];
    }];
}

-(NSArray *)broadcastList {
    
    NSMutableArray *list = [[NSMutableArray alloc] init];
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        FMResultSet *result = [db executeQuery:@"select * from broadcasts where 1=1 order by date"];
        while ([result next]) {
            TL_broadcast *broadcast = [TLClassStore deserialize:[result dataForColumn:@"serialized"]];
            
            [list addObject:broadcast];
        }
        
         [result close];
        
    }];
    
    
    return list;
    
}

-(void)insertSecretAction:(TGSecretAction *)action {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into out_secret_actions (action_id, message_data, chat_id, senderClass, layer) values (?,?,?,?,?)",@(action.actionId),action.decryptedData,@(action.chat_id),action.senderClass,@(action.layer)];
    }];
}


-(void)removeSecretAction:(TGSecretAction *)action {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from out_secret_actions where action_id = ?",@(action.actionId)];
    }];
}

-(void)selectAllActions:(void (^)(NSArray *list))completeHandler {
    
    
    [queue inDatabase:^(FMDatabase *db) {
        NSMutableArray *list = [[NSMutableArray alloc] init];
        FMResultSet *result = [db executeQuery:@"select * from out_secret_actions where 1=1 order by action_id"];
        while ([result next]) {
            TGSecretAction *action = [[TGSecretAction alloc] initWithActionId:[result intForColumn:@"action_id"] chat_id:[result intForColumn:@"chat_id"] decryptedData:[result dataForColumn:@"message_data"] senderClass:NSClassFromString([result stringForColumn:@"senderClass"]) layer:[result intForColumn:@"layer"]];
            
            [list addObject:action];
        }
        
        [result close];
        
        if(completeHandler) completeHandler(list);
        
    }];

}


-(void)insertSecretInAction:(TGSecretInAction *)action {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"insert or replace into in_secret_actions (action_id, message_data, file_data, chat_id, date, in_seq_no, layer) values (?,?,?,?,?,?,?)",@(action.actionId),action.messageData, action.fileData,@(action.chat_id),@(action.date),@(action.in_seq_no),@(action.layer)];
    }];
}
-(void)removeSecretInAction:(TGSecretInAction *)action {
    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"delete from in_secret_actions where action_id = ?",@(action.actionId)];
    }];
}

-(void)selectSecretInActions:(int)chat_id completeHandler:(void (^)(NSArray *list))completeHandler {
    [queue inDatabase:^(FMDatabase *db) {
        
        NSMutableArray *list = [[NSMutableArray alloc] init];
        
        FMResultSet *result = [db executeQuery:@"select * from in_secret_actions where chat_id=? order by in_seq_no",@(chat_id)];
        while ([result next]) {
            TGSecretInAction *action = [[TGSecretInAction alloc] initWithActionId:[result intForColumn:@"action_id"] chat_id:[result intForColumn:@"chat_id"] messageData:[result dataForColumn:@"message_data"] fileData:[result dataForColumn:@"file_data"] date:[result intForColumn:@"date"] in_seq_no:[result intForColumn:@"in_seq_no"] layer:[result intForColumn:@"layer"]];
            
            [list addObject:action];
        }
        
        [result close];
        
        if(completeHandler) completeHandler(list);
        
    }];
}


-(NSArray *)selectSupportMessages:(NSArray *)ids {
    
    NSMutableArray *messages = [[NSMutableArray alloc] init];
    
    [queue inDatabaseWithDealocing:^(FMDatabase *db) {
        
        NSString *join = [ids componentsJoinedByString:@","];
        
        
        NSString *sql = [NSString stringWithFormat:@"select * from support_messages where n_id IN (%@)",join];
        
        FMResultSet *result = [db executeQueryWithFormat:sql,nil];
        
        
        while ([result next]) {
            
            [messages addObject:[TLClassStore deserialize:[result dataForColumn:@"serialized"]]];
            
        }
        
        [result close];
        
    }];
    
    return messages;
    
}


-(void)addSupportMessages:(NSArray *)messages {
    [queue inDatabase:^(FMDatabase *db) {
        [messages enumerateObjectsUsingBlock:^(TL_localMessage *obj, NSUInteger idx, BOOL *stop) {
            [db executeUpdate:@"insert into support_messages (n_id,serialized) values (?,?)",@(obj.n_id),[TLClassStore serialize:obj]];
        }];
    }];
}



-(void)updateMessageId:(long)random_id msg_id:(int)n_id {
    [queue inDatabase:^(FMDatabase *db) {
        
        [db executeUpdate:@"update media set message_id = ? where message_id = (select n_id from messages where random_id = ?)",@(n_id),@(random_id)];
        
        [db executeUpdate:@"update messages set n_id = (?), dstate = (?) where random_id = ?",@(n_id),@(random_id),@(DeliveryStateNormal)];
        
    }];
}

+(void)addWebpage:(TLWebPage *)webpage forLink:(NSString *)link {
    
    [[Storage yap] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        
        [transaction setObject:[TLClassStore serialize:webpage] forKey:link inCollection:@"webpage"];
        
    }];
      
    
}

+(TLWebPage *)findWebpage:(NSString *)link {
    
    __block TLWebPage *webpage;
    
    
    [[Storage yap] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        
        NSData *wp = [transaction objectForKey:link inCollection:@"webpage"];
        if(wp)
            webpage = [TLClassStore deserialize:wp];
        
    }];
    
    return webpage;
    
}

@end
