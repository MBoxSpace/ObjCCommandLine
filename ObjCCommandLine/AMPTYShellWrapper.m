//
//  AMPTYShellWrapper.m
//  ObjCCommandLine
//
//  Created by lizhuoli on 2019/3/21.
//  Copyright © 2019 dijkst. All rights reserved.
//

#import "AMPTYShellWrapper.h"
#include <util.h>

@implementation AMPTYShellWrapper {
    NSFileHandle *masterHandle;
    NSFileHandle *slaveHandle;
    BOOL         stdoutEmpty;
}

// Do basic initialization

- (id)initWithLaunchPath:(NSString *)launch workingDirectory:(NSString *)directoryPath environment:(NSDictionary *)env arguments:(NSArray *)args context:(void *)pointer {
    if ((self = [super initWithLaunchPath:launch workingDirectory:directoryPath environment:env arguments:args context:pointer])) {
        
    }
    return self;
}

- (BOOL)setupTaskWithPTY {
    int master, slave;
    struct winsize size = { .ws_col = 40 };
    
    int rc = openpty(&master, &slave, NULL, NULL, &size);
    if (rc < 0) {
        return NO;
    }
    
    // The process's stdout && stderr is bind to PTY's stdin(slave)
    // The process's stdin is bind to PTY's stdout(master)
    masterHandle = [NSFileHandle.alloc initWithFileDescriptor:master closeOnDealloc:YES];
    slaveHandle  = [NSFileHandle.alloc initWithFileDescriptor:slave  closeOnDealloc:YES];
    
    task.standardOutput = masterHandle;
    task.standardError = masterHandle;
    task.standardInput = slaveHandle;
    
    return YES;
}


// must be called in main thread
// readInBackgroundAndNotifyForModes need a active run loop
- (void)startProcess {
    BOOL error = NO;
    // We first let the controller know that we are starting
    [self.delegate processStarted:self];
    
    
    error = ![self setupTaskWithPTY];
    
    if (!error) {
        // setting the current working directory
        if (workingDirectory != nil)
            [task setCurrentDirectoryPath:workingDirectory];
        
        // Setting the environment if available
        if (environment != nil)
            [task setEnvironment:environment];
        
        [task setLaunchPath:launchPath];
        
        [task setArguments:arguments];
        
        // Here we register as an observer of the NSFileHandleReadCompletionNotification,
        // which lets us know when there is data waiting for us to grab it in the task's file
        // handle (the pipe to which we connected stdout and stderr above).
        // -getData: will be called when there is data waiting. The reason we need to do this
        // is because if the file handle gets filled up, the task will block waiting to send
        // data and we'll never get anywhere. So we have to keep reading data from the file
        // handle as we go.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(getData:) name:NSFileHandleReadCompletionNotification object:slaveHandle];
        
        // We tell the file handle to go ahead and read in the background asynchronously,
        // and notify us via the callback registered above when we signed up as an observer.
        // The file handle will send a NSFileHandleReadCompletionNotification when it has
        // data that is available.
        [slaveHandle readInBackgroundAndNotifyForModes:@[NSRunLoopCommonModes]];
        
        // since waiting for the output pipes to run dry seems unreliable in terms of
        // deciding wether the task has died, we go the 'clean' route and wait for a notification
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskStopped:) name:NSTaskDidTerminateNotification object:task];
        
        // we will wait for data in stdout; there may be nothing to receive from stderr
        stdoutEmpty = NO;
        
        // launch the task asynchronously
        [task launch];
        
        // since the notification center does not retain the observer, make sure
        // we don't get deallocated early
    } else {
        [self performSelector:@selector(cleanup) withObject:nil afterDelay:0];
    }
}

// terminate the task
- (void)stopProcess {
    [task terminate];
}

// If the task ends, there is no more data coming through the file handle even when
// the notification is sent, or the process object is released, then this method is called.
- (void)cleanup {
    NSData *data;
    
    if (taskDidTerminate) {
        // It is important to clean up after ourselves so that we don't leave potentially
        // deallocated objects as observers in the notification center; this can lead to
        // crashes.
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        
        // Make sure the task has actually stopped!
        //[task terminate];
        
        // NSFileHandle availableData is a blocking read - what were they thinking? :-/
        // Umm - OK. It comes back when the file is closed. So here we go ...
        
        // clear slave stdout
        while ((data = [slaveHandle availableData]) && [data length]) {
            [self appendOutput:data];
        }
        
        self.terminationStatus = [task terminationStatus];
    }
    
    // we tell the controller that we finished, via the callback, and then blow away
    // our connection to the controller.  NSTasks are one-shot (not for reuse), so we
    // might as well be too.
    self.finish = YES;
    [self.delegate processFinished:self withTerminationStatus:self.terminationStatus];
    
    /*
     NSDictionary *userInfo = nil;
     // task has to go so we can't put it in a dictionary ...
     if (task) {
     userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[[task retain] autorelease], AMShellWrapperProcessFinishedNotificationTaskKey, [NSNumber numberWithInt:terminationStatus], AMShellWrapperProcessFinishedNotificationTerminationStatusKey, nil];
     } else {
     userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSNull null], AMShellWrapperProcessFinishedNotificationTaskKey, [NSNumber numberWithInt:terminationStatus], AMShellWrapperProcessFinishedNotificationTerminationStatusKey, nil];
     }
     
     [[NSNotificationCenter defaultCenter] postNotificationName:AMShellWrapperProcessFinishedNotification object:self userInfo:userInfo];
     */
    
    
    // we are done; go ahead and kill us if you like ...
}

// input to stdin
- (void)appendInput:(NSData *)input {
    [masterHandle writeData:input];
}

- (void)closeInput {
    [masterHandle closeFile];
}

- (void)appendOutput:(NSData *)data {
    [self.delegate process:self appendOutput:data];
}

- (void)appendError:(NSData *)data {
    [self.delegate process:self appendError:data];
}

- (void)waitData:(NSNotification *)aNotification {
    NSFileHandle *handle = aNotification.object;
    NSData *data = [handle availableData];
    
    // If the length of the data is zero, then the task is basically over - there is nothing
    // more to get from the handle so we may as well shut down.
    if ([data length]) {
        // Send the data on to the controller; we can't just use +stringWithUTF8String: here
        // because -[data bytes] is not necessarily a properly terminated string.
        // -initWithData:encoding: on the other hand checks -[data length]
        if (handle == slaveHandle) {
            [self appendOutput:data];
            stdoutEmpty = NO;
        } else {
            // this should really not happen ...
        }
        
        // we need to schedule the file handle go read more data in the background again.
        [handle waitForDataInBackgroundAndNotify];
    } else {
        if (handle == slaveHandle) {
            stdoutEmpty = YES;
        } else {
            // this should really not happen ...
        }
        // if there is no more data in the pipe AND the task did terminate, we are done
        if (stdoutEmpty && taskDidTerminate) {
            [self cleanup];
        }
    }
}

// This method is called asynchronously when data is available from the task's file handle.
// We just pass the data along to the controller as an NSString.
- (void)getData:(NSNotification *)aNotification {
    NSData *data;
    id     notificationObject;
    
    notificationObject = [aNotification object];
    data               = [[aNotification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    
    // If the length of the data is zero, then the task is basically over - there is nothing
    // more to get from the handle so we may as well shut down.
    if ([data length]) {
        // Send the data on to the controller; we can't just use +stringWithUTF8String: here
        // because -[data bytes] is not necessarily a properly terminated string.
        // -initWithData:encoding: on the other hand checks -[data length]
        if ([notificationObject isEqualTo:slaveHandle]) {
            [self appendOutput:data];
            stdoutEmpty = NO;
        } else {
            // this should really not happen ...
        }
        
        // we need to schedule the file handle go read more data in the background again.
        [notificationObject readInBackgroundAndNotify];
    } else {
        if ([notificationObject isEqualTo:slaveHandle]) {
            stdoutEmpty = YES;
        } else {
            // this should really not happen ...
        }
        // if there is no more data in the pipe AND the task did terminate, we are done
        if (stdoutEmpty && taskDidTerminate) {
            [self cleanup];
        }
    }
    
    // we need to schedule the file handle go read more data in the background again.
    //    [notificationObject readInBackgroundAndNotify];
}

- (void)taskStopped:(NSNotification *)aNotification {
    if (!taskDidTerminate) {
        // Close the PTY input fd after task finished
        [masterHandle closeFile];
        
        taskDidTerminate = YES;
        // did we receive all data?
        if (stdoutEmpty) {
            // no data left - do the clean up
            [self cleanup];
        }
    }
}

@end

