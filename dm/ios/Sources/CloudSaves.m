// See CloudSaves.h.

#import "CloudSaves.h"

static NSString *const kCloudSaves = @"cloudSavesBookmark";
static NSString *const kCloudSavesPath = @"cloudSavesPath";

// The folder's security scope, held from the first resolve on: the host writes there after every
// save. Never stopped on purpose, the process exits when the game does.
static NSURL *opened = nil;

static NSData *fresh_bookmark(NSURL *url) {
    // The picker grants a security scope that lasts while it is held: the bookmark is written with
    // the scope on. One written without it reads back on this run and resolves to nothing from the
    // next launch on.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return bookmark;
}

NSString *dm_cloud_saves_path(BOOL *stale) {
    if (stale) *stale = NO;
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kCloudSaves];
    NSString *savedPath = [NSUserDefaults.standardUserDefaults stringForKey:kCloudSavesPath];
    if (bookmark.length == 0 && savedPath.length == 0) return nil;
    BOOL isStale = NO;
    NSError *error = nil;
    NSURL *url = bookmark.length ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error] : nil;
    if (!url && savedPath.length) {
        // LiveContainer 等容器环境下可能无法解析 Bookmark，尝试直接访问路径
        NSURL *fallback = [NSURL fileURLWithPath:savedPath];
        [fallback startAccessingSecurityScopedResource];
        if ([NSFileManager.defaultManager isWritableFileAtPath:savedPath] || [NSFileManager.defaultManager fileExistsAtPath:savedPath]) {
            url = fallback;
            isStale = NO;
        }
    }
    if (!url) {
        // A re-signed build gets a bookmark the system will not resolve for it. Keep the data, the
        // player may install the same signature again, and let the launcher ask for a new pick.
        fprintf(stderr, "boot: the picked cloud-save folder bookmark does not resolve (%s)\n", error.localizedDescription.UTF8String ?: "no reason given");
        if (stale) *stale = YES;
        return nil;
    }
    if (opened && ![opened.path isEqualToString:url.path]) opened = nil;
    if (!opened) [url startAccessingSecurityScopedResource];   // held for the session (see opened)
    opened = url;
    if (isStale) {
        // The system still resolves it but asks for a rewrite. Same signature, so a fresh bookmark sticks.
        NSData *again = fresh_bookmark(url);
        if (again) [NSUserDefaults.standardUserDefaults setObject:again forKey:kCloudSaves];
        if (stale) *stale = YES;
    }
    return url.path;
}

BOOL dm_store_cloud_saves(NSURL *url) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    NSError *error = nil;
    NSURL *back = nil;
    if (bookmark) back = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:nil error:&error];
    if ((!bookmark || !back) && url.path.length) {
        // 在 LiveContainer 等环境下若 Bookmark 无法解析但路径本身可访问，依然允许保存路径
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            [NSUserDefaults.standardUserDefaults setObject:url.path forKey:kCloudSavesPath];
            if (bookmark) [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kCloudSaves];
            [NSUserDefaults.standardUserDefaults synchronize];
            opened = url;
            fprintf(stderr, "launcher: cloud-save folder set to %s (path fallback)\n", url.path.UTF8String);
            return YES;
        }
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!bookmark || !back) {
        // A bookmark that cannot come back is not saved as if it were good.
        fprintf(stderr, "[RED] could not bookmark %s: %s\n", url.path.UTF8String ?: "?",
                error.localizedDescription.UTF8String ?: (bookmark ? "the bookmark does not resolve again" : "no bookmark data"));
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kCloudSaves];
    if (url.path.length) [NSUserDefaults.standardUserDefaults setObject:url.path forKey:kCloudSavesPath];
    [NSUserDefaults.standardUserDefaults synchronize];
    fprintf(stderr, "launcher: cloud-save folder set to %s\n", url.path.UTF8String ?: "?");
    return YES;
}

void dm_clear_cloud_saves(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kCloudSaves];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kCloudSavesPath];
    [NSUserDefaults.standardUserDefaults synchronize];
}

void dm_cloud_saves_env(void) {
    static BOOL fromPick;   // DM_SAVE_SYNC is the one this set, not an env file's
    if (getenv("DM_SAVE_SYNC") && !fromPick) return;
    BOOL stale = NO;
    NSString *folder = dm_cloud_saves_path(&stale);
    if (stale && !folder) fprintf(stderr, "boot: the cloud-save folder needs to be chosen again (the app is signed differently now); cloud saves are off\n");
    if (folder.length) {
        setenv("DM_SAVE_SYNC", folder.fileSystemRepresentation, 1); fromPick = YES;
        fprintf(stderr, "boot: cloud saves through %s\n", folder.fileSystemRepresentation);
    } else if (fromPick) { unsetenv("DM_SAVE_SYNC"); fromPick = NO; }
}
