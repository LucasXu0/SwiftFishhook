//
//  Replacement.h
//  SwiftFishhook
//
//  Created by xurunkang on 2020/2/1.
//  Copyright © 2020 xurunkang. All rights reserved.
//

#import <Foundation/Foundation.h>

int (*origin_open)(const char *, int, ...);
void *replacement_open(void);
void *replaced_open(void);
