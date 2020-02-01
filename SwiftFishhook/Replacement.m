//
//  Replacement.c
//  SwiftFishhook
//
//  Created by xurunkang on 2020/2/1.
//  Copyright © 2020 xurunkang. All rights reserved.
//

#include "Replacement.h"

int my_open(const char *path, int oflag, ...) {
  va_list ap = {0};
  mode_t mode = 0;

  if ((oflag & O_CREAT) != 0) {
    // mode only applies to O_CREAT
    va_start(ap, oflag);
    mode = va_arg(ap, int);
    va_end(ap);
    printf("Calling real open('%s', %d, %d)\n", path, oflag, mode);
    return origin_open(path, oflag, mode);
  } else {
    printf("Calling real open('%s', %d)\n", path, oflag);
    return origin_open(path, oflag, mode);
  }
}

void* replacement_open() {
    return my_open;
}

void* replaced_open() {
    return &origin_open;
}
