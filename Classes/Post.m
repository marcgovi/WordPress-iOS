// 
//  Post.m
//  WordPress
//
//  Created by Chris Boyd on 8/9/10.
//

#import "Post.h"
#import "WPDataController.h"

@interface Post(PrivateMethods)
+ (Post *)newPostForBlog:(Blog *)blog;
- (void)uploadInBackground;
- (void)didUploadInBackground;
- (void)failedUploadInBackground;
@end

@implementation Post 

@dynamic geolocation, tags;
@dynamic latitudeID, longitudeID, publicID;
@dynamic categories, comments;

+ (Post *)newPostForBlog:(Blog *)blog {
    Post *post = [[Post alloc] initWithEntity:[NSEntityDescription entityForName:@"Post"
                                                          inManagedObjectContext:[blog managedObjectContext]]
               insertIntoManagedObjectContext:[blog managedObjectContext]];

    post.blog = blog;
    
    return post;
}

+ (Post *)newDraftForBlog:(Blog *)blog {
    Post *post = [self newPostForBlog:blog];
    post.remoteStatus = AbstractPostRemoteStatusLocal;
    post.status = @"publish";
    [post save];
    
    return post;
}

+ (Post *)findWithBlog:(Blog *)blog andPostID:(NSNumber *)postID {
    NSSet *results = [blog.posts filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"postID == %@ AND original == NULL",postID]];
    
    if (results && (results.count > 0)) {
        return [[results allObjects] objectAtIndex:0];
    }
    return nil;
}

+ (Post *)createOrReplaceFromDictionary:(NSDictionary *)postInfo forBlog:(Blog *)blog {
    Post *post = [self findWithBlog:blog andPostID:[[postInfo objectForKey:@"postid"] numericValue]];
    
    if (post == nil) {
        post = [[Post newPostForBlog:blog] autorelease];
    }
    
    post.postTitle      = [postInfo objectForKey:@"title"];
    post.postID         = [[postInfo objectForKey:@"postid"] numericValue];
    post.content        = [postInfo objectForKey:@"description"];
    post.date_created_gmt    = [postInfo objectForKey:@"date_created_gmt"];
    post.status         = [postInfo objectForKey:@"post_status"];
    post.password       = [postInfo objectForKey:@"wp_password"];
    post.tags           = [postInfo objectForKey:@"mt_keywords"];
	post.permaLink      = [postInfo objectForKey:@"permaLink"];
	post.mt_excerpt		= [postInfo objectForKey:@"mt_excerpt"];
	post.mt_text_more	= [postInfo objectForKey:@"mt_text_more"];
	post.wp_slug		= [postInfo objectForKey:@"wp_slug"];
	
    post.remoteStatus   = AbstractPostRemoteStatusSync;
    if ([postInfo objectForKey:@"categories"]) {
        [post setCategoriesFromNames:[postInfo objectForKey:@"categories"]];
    }
	if ([postInfo objectForKey:@"custom_fields"]) {
		NSArray *customFields = [postInfo objectForKey:@"custom_fields"];
		NSString *geo_longitude = nil;
		NSString *geo_latitude = nil;
		NSString *geo_longitude_id = nil;
		NSString *geo_latitude_id = nil;
		NSString *geo_public_id = nil;
		for (NSDictionary *customField in customFields) {
			NSString *ID = [customField objectForKey:@"id"];
			NSString *key = [customField objectForKey:@"key"];
			NSString *value = [customField objectForKey:@"value"];
			
			if (key) {
				if ([key isEqualToString:@"geo_longitude"]) {
					geo_longitude = value;
					geo_longitude_id = ID;
				} else if ([key isEqualToString:@"geo_latitude"]) {
					geo_latitude = value;
					geo_latitude_id = ID;
				} else if ([key isEqualToString:@"geo_public"]) {
					geo_public_id = ID;
				}
			}
		}
		
		if (geo_latitude && geo_longitude) {
			Coordinate *c = [[Coordinate alloc] initWithCoordinate:CLLocationCoordinate2DMake([geo_latitude doubleValue], [geo_longitude doubleValue])];
			post.geolocation = c;
			post.latitudeID = geo_latitude_id;
			post.longitudeID = geo_longitude_id;
			post.publicID = geo_public_id;
			[c release];
		}
	}
    [post findComments];
    
    return post;
}

- (void)removeWithError:(NSError **)error {
    if ([self hasRemote]) {
		WPDataController *dc = [[WPDataController alloc] init];
		[dc  mwDeletePost:self];
		if(dc.error) {
			*error = dc.error;
			WPLog(@"Error while deleting post: %@", [*error localizedDescription]);
		} else {
			[super removeWithError:nil]; 
		}
		[dc release];
	} else {
		//we should remove the post from the db even if it is a "LocalDraft"
		[super removeWithError:nil]; 
	}
}

- (void)uploadInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if ([self hasRemote]) {
        if ([[WPDataController sharedInstance] mwEditPost:self]) {
            self.remoteStatus = AbstractPostRemoteStatusSync;
            [self performSelectorOnMainThread:@selector(didUploadInBackground) withObject:nil waitUntilDone:NO];
        } else {
            NSLog(@"Post update failed");
            self.remoteStatus = AbstractPostRemoteStatusFailed;
            [self performSelectorOnMainThread:@selector(failedUploadInBackground) withObject:nil waitUntilDone:NO];
        }
    } else {
        int postID = [[WPDataController sharedInstance] mwNewPost:self];
        if (postID == -1) {
            NSLog(@"Post upload failed");
            self.remoteStatus = AbstractPostRemoteStatusFailed;
            [self performSelectorOnMainThread:@selector(failedUploadInBackground) withObject:nil waitUntilDone:NO];
        } else {
            self.postID = [NSNumber numberWithInt:postID];
            self.remoteStatus = AbstractPostRemoteStatusSync;
            [self performSelectorOnMainThread:@selector(didUploadInBackground) withObject:nil waitUntilDone:NO];
        }
    }
    [self save];

    [pool release];
}

- (void)didUploadInBackground {
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PostUploaded" object:self];
}

- (void)failedUploadInBackground {
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PostUploadFailed" object:self];
}

- (void)upload {
    if ([self.password isEmpty])
        self.password = nil;

    [super upload];
    [self save];

    self.remoteStatus = AbstractPostRemoteStatusPushing;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    [self performSelectorInBackground:@selector(uploadInBackground) withObject:nil];
}

- (void)autosave {
    NSError *error = nil;
    if (![[self managedObjectContext] save:&error]) {
        // We better not crash on autosave
        NSLog(@"[Autosave] Unresolved Core Data Save error %@, %@", error, [error userInfo]);
        [FlurryAPI logError:@"Autosave" message:[error localizedDescription] error:error];
    }
}

- (NSString *)categoriesText {
    return [[[self.categories valueForKey:@"categoryName"] allObjects] componentsJoinedByString:@", "];
}

- (void)setCategoriesFromNames:(NSArray *)categoryNames {
    [self.categories removeAllObjects];
    for (NSString *categoryName in categoryNames) {
        NSSet *results = [self.blog.categories filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"categoryName like %@", categoryName]];
        if (results && (results.count > 0)) {
            self.categories = [NSMutableSet setWithSet:results];
        }
    }
}

- (BOOL)hasChanges {
    if ([super hasChanges]) return YES;

    if ((self.tags != ((Post *)self.original).tags)
        && (![self.tags isEqual:((Post *)self.original).tags]))
        return YES;

    if (![self.categories isEqual:((Post *)self.original).categories]) return YES;

    return NO;
}

- (void)findComments {
    NSSet *comments = [self.blog.comments filteredSetUsingPredicate:
                       [NSPredicate predicateWithFormat:@"(postID == %@) AND (post == NULL)", self.postID]];
    if (comments && [comments count] > 0) {
        [self.comments unionSet:comments];
    }
}

@end
