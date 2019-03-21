//
//  AMPTYShellWrapper.h
//  ObjCCommandLine
//
//  Created by lizhuoli on 2019/3/21.
//  Copyright © 2019 dijkst. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AMShellWrapper.h"

// Use the PTY (pseudo-tty) instead of pipe to simulate a actual terminal, support input && output

/**
 PTY模式和Pipe的区别在于：
 1）PTY下，使用系统调用创建了个模拟终端，把命令行进程的stdout，转移到终端的stdin上（呈现到屏幕上）；终端的stdout，对应命令行的stdin（键盘输入）
 2）Pipe下，使用Pipe把命令行进程的stdout，pipe到了一个临时的file handler，然后读取它；同时，把所有当前进程的stdin，pipe到了命令行进程的stdin
 */
@interface AMPTYShellWrapper : AMShellWrapper

@end
