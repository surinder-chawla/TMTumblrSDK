//
//  TMEncodableMultipartFormData.m
//  TMTumblrSDK
//
//  Created by Pinar Olguc on 5.05.2021.
//

#import "TMEncodableMultipartFormData.h"
#import "TMMultipartPartProtocol.h"
#import "TMInputStreamMultipartPart.h"
#import "TMMultipartConstants.h"
#import "TMMultipartPart.h"

NSString * const TMMultipartFormErrorDomain = @"com.tumblr.sdk.multipartform";

// Value taken from Apple doc: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Streams/Articles/ReadingInputStreams.html
NSUInteger const TMMaxBufferSize = 1024;

@interface TMEncodableMultipartFormData ()

@property (nonatomic) NSFileManager *fileManager;
@property (nonatomic) NSString *boundary;
@property (nonatomic) NSMutableArray <id<TMMultipartPartProtocol>> *parts;

@end

@implementation TMEncodableMultipartFormData

- (nonnull instancetype)initWithFileManager:(nonnull NSFileManager *)fileManager boundary:(nonnull NSString *)boundary {
    NSParameterAssert(fileManager);
    NSParameterAssert(boundary);
    self = [super init];
    
    if (self) {
        _fileManager = fileManager;
        _boundary = [boundary copy];
        _parts = [NSMutableArray new];
    }
    
    return self;
}

- (void)appendFileURL:(nonnull NSURL *)fileURL
                 name:(nonnull NSString *)name
          contentType:(nonnull NSString *)contentType
                error:(NSError **)error {
    
    // Is the url uses the file scheme?
    if (!fileURL.isFileURL) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeURLNotUsingFileScheme userInfo:nil];
        return;
    }
    
    // Is the file name is valid?
    NSString *fileName = fileURL.lastPathComponent;
    if (!(fileName.length > 0)) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeFileNameNotValid userInfo:nil];
        return;
    }

    // Is the URL points to a file or a directory?
    BOOL isDirectory = false;
    if ([self.fileManager fileExistsAtPath:fileURL.path isDirectory:&isDirectory] && !isDirectory) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeFileIsDirectory userInfo:nil];
        return;
    }
    
    // Is the file reachable?
    NSError *reachableError;
    if (![fileURL checkResourceIsReachableAndReturnError:&reachableError]) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeFileNotReachable userInfo:reachableError.userInfo];
        return;
    }
    
    // File size can be captured?
    NSNumber *fileSizeNumber = [[_fileManager attributesOfItemAtPath:fileURL.path error:nil] objectForKey:NSFileSize];
    if (!fileSizeNumber) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeFileSizeNotAvailable userInfo:nil];
        return;
    }
    UInt64 contentLength = fileSizeNumber.longLongValue;
    
    // Can we create the input stream?
    NSInputStream *inputStream = [[NSInputStream alloc] initWithURL:fileURL];
    if (!inputStream) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeInputStreamCreationFailed userInfo:nil];
        return;
    }
    
    [self appendInputStream:inputStream contentLength:contentLength name:name fileName:fileName contentType:contentType];
}

- (void)appendData:(nonnull NSData *)data
              name:(nonnull NSString *)name
          fileName:(nullable NSString *)fileName
       contentType:(nonnull NSString *)contentType {
    
    NSInputStream *inputStream = [[NSInputStream alloc] initWithData:data];
    [self appendInputStream:inputStream contentLength:data.length name:name fileName:fileName contentType:contentType];
    
}

- (void)appendInputStream:(nonnull NSInputStream *)inputStream
            contentLength:(UInt64)contentLength
                     name:(nonnull NSString *)name
                 fileName:(nullable NSString *)fileName
              contentType:(nonnull NSString *)contentType {
    
    TMInputStreamMultipartPart *part = [[TMInputStreamMultipartPart alloc] initWithInputStream:inputStream name:name fileName:fileName contentType:contentType contentLength:contentLength];
    [self.parts addObject:part];
}

- (void)writePartsToFileURL:(NSURL *)targetFileURL error:(NSError **)error {
    if ([self.fileManager fileExistsAtPath:targetFileURL.path]) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeOutputFileAlreadyExists userInfo:nil];
        return;
    }
    if (!targetFileURL.isFileURL) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeOutputFileURLInvalid userInfo:nil];
        return;
    }
    
    NSOutputStream *outputStream = [[NSOutputStream alloc] initWithURL:targetFileURL append:false];
    if (!outputStream) {
        *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeOutputStreamCreationFailed userInfo:nil];
        return;
    }
    
    [outputStream open];
    
    [self.parts.firstObject setHasTopBoundary:YES];
    [self.parts.lastObject setHasBottomBoundary:YES];
    
    for (id<TMMultipartPartProtocol> part in self.parts) {
        [self writeBodyPart:part toOutputStream:outputStream error:error];
    }
    
    [outputStream close];
}

- (void)writeBodyPart:(id<TMMultipartPartProtocol>)part toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    
    // Write top boundary
    
    [self writeTopBoundaryForBodyPart:part toOutputStream:outputStream error:error];
    if (*error) {
        return;
    }
    
    // Write headers
    
    [self writeHeadersForBodyPart:part toOutputStream:outputStream error:error];
    if (*error) {
        return;
    }
    
    // Write streamable
    
    if ([part isKindOfClass: [TMInputStreamMultipartPart class]]) {
        TMInputStreamMultipartPart *streamblePart = (TMInputStreamMultipartPart *)part;
        [self writeBodyStreamForPart:streamblePart toOutputStream:outputStream error:error];
        if (*error) {
            return;
        }
    }
    
    // Write non streamable
    
    if ([part isKindOfClass:[TMMultipartPart class]]) {
        TMMultipartPart *nonStreamablePart = (TMMultipartPart *)part;
        [self writeData:nonStreamablePart.data toOutputStream:outputStream error:error];
        if (*error) {
            return;
        }
    }
    
    // Write bottom boundary
    
    [self writeBottomBoundaryForBodyPart:part toOutputStream:outputStream error:error];
}

- (void)writeTopBoundaryForBodyPart:(id<TMMultipartPartProtocol>)part toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    NSString *prefixedBoundary = [@"--" stringByAppendingString:self.boundary];
    
    NSMutableString *topBoundary = [[NSMutableString alloc] init];
    [topBoundary appendString:prefixedBoundary];
    [topBoundary appendString:TMMultipartCRLF];
    
    NSData *data = [topBoundary dataUsingEncoding:NSUTF8StringEncoding];
    [self writeData:data toOutputStream:outputStream error:error];
}

- (void)writeHeadersForBodyPart:(id<TMMultipartPartProtocol>)part toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    NSMutableString *string = [[NSMutableString alloc] init];

    [string appendFormat:@"Content-Disposition: form-data; name=\"%@\"", part.name];

    if (part.fileName) {
        [string appendFormat:@"; filename=\"%@\"", part.fileName];
    }
    [string appendString:TMMultipartCRLF];
    [string appendFormat:@"Content-Type: %@", part.contentType];
    [string appendString:TMMultipartCRLF];
    [string appendString:TMMultipartCRLF];
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self writeData:data toOutputStream:outputStream error:error];
}

- (void)writeBottomBoundaryForBodyPart:(id<TMMultipartPartProtocol>)part toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    NSData *data = [TMMultipartCRLF dataUsingEncoding:NSUTF8StringEncoding];
    [self writeData:data toOutputStream:outputStream error:error];
}

- (void)writeData:(NSData *)data toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    Byte *readBytes = (uint8_t *)[[NSData dataWithData:data] bytes];
    NSUInteger length = data.length;
    Byte buffer[length];
    (void)memcpy(buffer, readBytes, length);
    [self writeBuffer:buffer oflength:length toOutputStream:outputStream error:error];
}

- (void)writeBodyStreamForPart:(TMInputStreamMultipartPart *)part toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
    NSInputStream *inputStream = part.inputStream;
    [inputStream open];
    
    while (inputStream.hasBytesAvailable) {
        uint8_t buffer[TMMaxBufferSize];
        (void)memset(buffer, 0, TMMaxBufferSize);

        NSInteger bytesRead = [inputStream read:buffer maxLength:TMMaxBufferSize];
        if (inputStream.streamError) {
            *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeInputStreamReadFailed userInfo:inputStream.streamError.userInfo];
            return;
        }
        if (bytesRead > 0) {
            [self writeBuffer:buffer oflength:bytesRead toOutputStream:outputStream error:error];
        }
        else {
            break;
        }
    }
    
    [inputStream close];
}

- (void)writeBuffer:(Byte *)buffer oflength:(NSUInteger)length toOutputStream:(NSOutputStream *)outputStream error:(NSError **)error {
        
    NSInteger bytesToWrite = length;
    while (bytesToWrite > 0 && outputStream.hasSpaceAvailable) {
        NSUInteger writtenLength = [outputStream write:buffer maxLength:length];
        if (outputStream.streamError) {
            *error = [[NSError alloc] initWithDomain:TMMultipartFormErrorDomain code:TMMultipartFormErrorTypeOutputStreamWriteFailed userInfo:outputStream.streamError.userInfo];
            return;
        }
        
        bytesToWrite -= writtenLength;

        if (bytesToWrite > 0) {
            (void)memcpy(buffer, buffer + writtenLength, bytesToWrite);
        }
    }
}
@end
