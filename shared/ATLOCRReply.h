#ifndef ATL_OCR_REPLY_H
#define ATL_OCR_REPLY_H
#import <Foundation/Foundation.h>
#include <math.h>
#include <string.h>
#include "ATLOCRProtocol.h"
#include "ATLOCRGeometry.h"
typedef struct { char text[512]; double x,y,width,height,confidence; } ATTextLine;
typedef struct { int count; ATTextLine lines[64]; } ATTextResult;
static inline BOOL ATLOCRReplyError(NSString **error, NSString *message) {
    if (error) *error=message ?: @"Invalid OCR response";
    return NO;
}
static inline BOOL ATLDecodeOCRReply(NSData *data, NSString *requestID,
        int w,int h,double scale,ATTextResult *out,NSString **error) {
    if (!out || !data.length || data.length>ATL_OCR_OUTPUT_LIMIT || w<=0 || h<=0 || !isfinite(scale) || scale<=0)
        return ATLOCRReplyError(error,@"Invalid OCR input or output bound");
    id reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"requestId"] isEqual:requestID] ||
        ![reply[@"version"] isKindOfClass:NSNumber.class] || [reply[@"version"] intValue]!=ATL_OCR_PROTOCOL_VERSION ||
        ![reply[@"ok"] isKindOfClass:NSNumber.class]) return ATLOCRReplyError(error,@"OCR protocol/request mismatch");
    if (![reply[@"ok"] boolValue]) {
        id reason=reply[@"errorMessage"];
        return ATLOCRReplyError(error,[reason isKindOfClass:NSString.class] && [reason length]<=1024 ? reason : @"OCR worker failed");
    }
    if (![reply[@"mode"] isEqual:@"accurate"] || ![reply[@"languages"] isEqual:(@[@"zh-Hans",@"en-US"])])
        return ATLOCRReplyError(error,@"OCR recognition capability mismatch");
    id lines=reply[@"lines"];
    if (![lines isKindOfClass:NSArray.class] || [lines count]>ATL_OCR_LINE_LIMIT)
        return ATLOCRReplyError(error,@"Invalid OCR result list");
    ATTextResult parsed={0};
    for (id item in lines) {
        if (![item isKindOfClass:NSDictionary.class]) return ATLOCRReplyError(error,@"Invalid OCR row");
        id text=item[@"text"];
        if (![text isKindOfClass:NSString.class] || ![text length] ||
            [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>ATL_OCR_TEXT_LIMIT ||
            [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
            return ATLOCRReplyError(error,@"Invalid OCR text");
        double values[5];NSUInteger i=0;
        for (NSString *key in @[@"x",@"y",@"width",@"height",@"confidence"]) {
            id value=item[key];
            if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]))
                return ATLOCRReplyError(error,@"Invalid OCR numeric result");
            values[i++]=[value doubleValue];
        }
        if (values[4]<0 || values[4]>1 || !ATLNormalizeOCRBox(&values[0],&values[1],&values[2],&values[3],w,h))
            return ATLOCRReplyError(error,@"OCR box outside frame");
        ATTextLine *line=&parsed.lines[parsed.count];
        if (![text getCString:line->text maxLength:sizeof(line->text) encoding:NSUTF8StringEncoding])
            return ATLOCRReplyError(error,@"Invalid OCR UTF-8");
        line->x=values[0]*w/scale;line->y=values[1]*h/scale;
        line->width=values[2]*w/scale;line->height=values[3]*h/scale;line->confidence=values[4];
        parsed.count++;
    }
    *out=parsed;
    return YES;
}
#endif
