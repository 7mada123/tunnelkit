//
//  CryptoAEAD.m
//  TunnelKit
//
//  Created by Davide De Rosa on 7/6/18.
//  Copyright (c) 2018 Davide De Rosa. All rights reserved.
//
//  https://github.com/keeshux
//
//  This file is part of TunnelKit.
//
//  TunnelKit is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  TunnelKit is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with TunnelKit.  If not, see <http://www.gnu.org/licenses/>.
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import <openssl/evp.h>
#import <openssl/hmac.h>
#import <openssl/rand.h>

#import "CryptoAEAD.h"
#import "CryptoMacros.h"
#import "Allocation.h"
#import "Errors.h"

const NSInteger CryptoAEADTagLength     = 16;

@interface CryptoAEAD ()

@property (nonatomic, unsafe_unretained) const EVP_CIPHER *cipher;
@property (nonatomic, assign) int cipherKeyLength;
@property (nonatomic, assign) int cipherIVLength; // 12 (AD packetId + HMAC key)
@property (nonatomic, assign) int overheadLength;
@property (nonatomic, assign) int extraPacketIdOffset;

@property (nonatomic, unsafe_unretained) EVP_CIPHER_CTX *cipherCtxEnc;
@property (nonatomic, unsafe_unretained) EVP_CIPHER_CTX *cipherCtxDec;
@property (nonatomic, unsafe_unretained) uint8_t *cipherIVEnc;
@property (nonatomic, unsafe_unretained) uint8_t *cipherIVDec;

@end

@implementation CryptoAEAD

- (instancetype)initWithCipherName:(NSString *)cipherName
{
    NSParameterAssert([[cipherName uppercaseString] hasSuffix:@"GCM"]);
    
    self = [super init];
    if (self) {
        self.cipher = EVP_get_cipherbyname([cipherName cStringUsingEncoding:NSASCIIStringEncoding]);
        NSAssert(self.cipher, @"Unknown cipher '%@'", cipherName);
        
        self.cipherKeyLength = EVP_CIPHER_key_length(self.cipher);
        self.cipherIVLength = EVP_CIPHER_iv_length(self.cipher);
        self.overheadLength = CryptoAEADTagLength;
        self.extraLength = PacketIdLength;
        self.extraPacketIdOffset = 0;
        
        self.cipherCtxEnc = EVP_CIPHER_CTX_new();
        self.cipherCtxDec = EVP_CIPHER_CTX_new();
        self.cipherIVEnc = allocate_safely(self.cipherIVLength);
        self.cipherIVDec = allocate_safely(self.cipherIVLength);
    }
    return self;
}

- (void)dealloc
{
    EVP_CIPHER_CTX_free(self.cipherCtxEnc);
    EVP_CIPHER_CTX_free(self.cipherCtxDec);
    bzero(self.cipherIVEnc, self.cipherIVLength);
    bzero(self.cipherIVDec, self.cipherIVLength);
    free(self.cipherIVEnc);
    free(self.cipherIVDec);

    self.cipher = NULL;
}

#pragma mark Encrypter

- (void)configureEncryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    NSParameterAssert(cipherKey.count >= self.cipherKeyLength);
    
    EVP_CIPHER_CTX_reset(self.cipherCtxEnc);
    EVP_CipherInit(self.cipherCtxEnc, self.cipher, cipherKey.bytes, NULL, 1);

    [self prepareIV:self.cipherIVEnc withHMACKey:hmacKey];
}

- (NSData *)encryptData:(NSData *)data offset:(NSInteger)offset extra:(nonnull const uint8_t *)extra error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(data);
    NSParameterAssert(extra);

    const uint8_t *bytes = data.bytes + offset;
    const int length = (int)(data.length - offset);
    const int maxOutputSize = (int)safe_crypto_capacity(data.length, self.overheadLength);

    NSMutableData *dest = [[NSMutableData alloc] initWithLength:maxOutputSize];
    NSInteger encryptedLength = INT_MAX;
    if (![self encryptBytes:bytes length:length dest:dest.mutableBytes destLength:&encryptedLength extra:extra error:error]) {
        return nil;
    }
    dest.length = encryptedLength;
    return dest;
}

- (BOOL)encryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength extra:(nonnull const uint8_t *)extra error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(extra);

    int l1 = 0, l2 = 0;
    int x = 0;
    int code = 1;

    assert(self.extraLength >= PacketIdLength);
    memcpy(self.cipherIVEnc, extra + self.extraPacketIdOffset, PacketIdLength);
    
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherInit(self.cipherCtxEnc, NULL, NULL, self.cipherIVEnc, -1);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxEnc, NULL, &x, extra, self.extraLength);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxEnc, dest + CryptoAEADTagLength, &l1, bytes, (int)length);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherFinal(self.cipherCtxEnc, dest + CryptoAEADTagLength + l1, &l2);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(self.cipherCtxEnc, EVP_CTRL_GCM_GET_TAG, CryptoAEADTagLength, dest);

    *destLength = CryptoAEADTagLength + l1 + l2;

//    NSLog(@">>> ENC iv: %@", [NSData dataWithBytes:self.cipherIVEnc length:self.cipherIVLength]);
//    NSLog(@">>> ENC ad: %@", [NSData dataWithBytes:extra length:self.extraLength]);
//    NSLog(@">>> ENC x: %d", x);
//    NSLog(@">>> ENC tag: %@", [NSData dataWithBytes:dest length:CryptoAEADTagLength]);
//    NSLog(@">>> ENC dest: %@", [NSData dataWithBytes:dest + CryptoAEADTagLength length:*destLength - CryptoAEADTagLength]);

    TUNNEL_CRYPTO_RETURN_STATUS(code)
}

- (id<DataPathEncrypter>)dataPathEncrypter
{
    return [[DataPathCryptoAEAD alloc] initWithCrypto:self];
}

#pragma mark Decrypter

- (void)configureDecryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    NSParameterAssert(cipherKey.count >= self.cipherKeyLength);
    
    EVP_CIPHER_CTX_reset(self.cipherCtxDec);
    EVP_CipherInit(self.cipherCtxDec, self.cipher, cipherKey.bytes, NULL, 0);
    
    [self prepareIV:self.cipherIVDec withHMACKey:hmacKey];
}

- (NSData *)decryptData:(NSData *)data offset:(NSInteger)offset extra:(nonnull const uint8_t *)extra error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(data);
    NSParameterAssert(extra);

    const uint8_t *bytes = data.bytes + offset;
    const int length = (int)(data.length - offset);
    const int maxOutputSize = (int)safe_crypto_capacity(data.length, self.overheadLength);

    NSMutableData *dest = [[NSMutableData alloc] initWithLength:maxOutputSize];
    NSInteger decryptedLength;
    if (![self decryptBytes:bytes length:length dest:dest.mutableBytes destLength:&decryptedLength extra:extra error:error]) {
        return nil;
    }
    dest.length = decryptedLength;
    return dest;
}

- (BOOL)decryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength extra:(nonnull const uint8_t *)extra error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(extra);

    int l1 = 0, l2 = 0;
    int x = 0;
    int code = 1;
    
    assert(self.extraLength >= PacketIdLength);
    memcpy(self.cipherIVDec, extra + self.extraPacketIdOffset, PacketIdLength);

    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherInit(self.cipherCtxDec, NULL, NULL, self.cipherIVDec, -1);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(self.cipherCtxDec, EVP_CTRL_GCM_SET_TAG, CryptoAEADTagLength, (uint8_t *)bytes);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxDec, NULL, &x, extra, self.extraLength);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxDec, dest, &l1, bytes + CryptoAEADTagLength, (int)length - CryptoAEADTagLength);
    TUNNEL_CRYPTO_TRACK_STATUS(code) EVP_CipherFinal(self.cipherCtxDec, dest + l1, &l2);

    *destLength = l1 + l2;
    
//    NSLog(@">>> DEC iv: %@", [NSData dataWithBytes:self.cipherIVDec length:self.cipherIVLength]);
//    NSLog(@">>> DEC ad: %@", [NSData dataWithBytes:extra length:self.extraLength]);
//    NSLog(@">>> DEC x: %d", x);
//    NSLog(@">>> DEC tag: %@", [NSData dataWithBytes:bytes length:CryptoAEADTagLength]);
//    NSLog(@">>> DEC dest: %@", [NSData dataWithBytes:dest length:*destLength]);

    TUNNEL_CRYPTO_RETURN_STATUS(code)
}

- (id<DataPathDecrypter>)dataPathDecrypter
{
    return [[DataPathCryptoAEAD alloc] initWithCrypto:self];
}

#pragma mark Helpers

- (void)prepareIV:(uint8_t *)iv withHMACKey:(ZeroingData *)hmacKey
{
    bzero(iv, PacketIdLength);
    memcpy(iv + PacketIdLength, hmacKey.bytes, self.cipherIVLength - PacketIdLength);
}

@end

#pragma mark -

@interface DataPathCryptoAEAD ()

@property (nonatomic, strong) CryptoAEAD *crypto;
@property (nonatomic, assign) int headerLength;
@property (nonatomic, copy) void (^setDataHeader)(uint8_t *, uint8_t);
@property (nonatomic, copy) BOOL (^checkPeerId)(const uint8_t *);

@end

@implementation DataPathCryptoAEAD

- (instancetype)initWithCrypto:(CryptoAEAD *)crypto
{
    if ((self = [super init])) {
        self.crypto = crypto;
        self.peerId = PacketPeerIdDisabled;
    }
    return self;
}

#pragma mark DataPathChannel

- (int)overheadLength
{
    return self.crypto.overheadLength;
}

- (void)setPeerId:(uint32_t)peerId
{
    _peerId = peerId & 0xffffff;
    
    if (_peerId == PacketPeerIdDisabled) {
        self.headerLength = 1;
        self.crypto.extraLength = PacketIdLength;
        self.crypto.extraPacketIdOffset = 0;
        self.setDataHeader = ^(uint8_t *to, uint8_t key) {
            PacketHeaderSet(to, PacketCodeDataV1, key);
        };
    }
    else {
        self.headerLength = 4;
        self.crypto.extraLength = self.headerLength + PacketIdLength;
        self.crypto.extraPacketIdOffset = self.headerLength;
        self.setDataHeader = ^(uint8_t *to, uint8_t key) {
            PacketHeaderSetDataV2(to, key, peerId);
        };
        self.checkPeerId = ^BOOL(const uint8_t *ptr) {
            return (PacketHeaderGetDataV2PeerId(ptr) == self.peerId);
        };
    }
}

#pragma mark DataPathEncrypter

- (void)assembleDataPacketWithPacketId:(uint32_t)packetId payload:(NSData *)payload into:(uint8_t *)dest length:(NSInteger *)length
{
    uint8_t *ptr = dest;
    memcpy(ptr, payload.bytes, payload.length);
    *length = (int)(ptr - dest + payload.length);

    switch (self.compressionFraming) {
        case CompressionFramingDisabled:
            memcpy(ptr, payload.bytes, payload.length);
            break;
            
        case CompressionFramingCompress:
            memcpy(ptr, payload.bytes, payload.length);
            ptr[payload.length] = *ptr;
            *ptr = CompressionFramingNoCompressSwap;
            *length += sizeof(uint8_t);
            break;
            
        case CompressionFramingCompLZO:
            memcpy(ptr + sizeof(uint8_t), payload.bytes, payload.length);
            *ptr = CompressionFramingNoCompress;
            *length += sizeof(uint8_t);
            break;
            
        default:
            break;
    }
}

- (NSData *)encryptedDataPacketWithKey:(uint8_t)key packetId:(uint32_t)packetId payload:(const uint8_t *)payload payloadLength:(NSInteger)payloadLength error:(NSError *__autoreleasing *)error
{
    const int capacity = self.headerLength + PacketIdLength + (int)safe_crypto_capacity(payloadLength, self.crypto.overheadLength);
    NSMutableData *encryptedPacket = [[NSMutableData alloc] initWithLength:capacity];
    uint8_t *ptr = encryptedPacket.mutableBytes;
    NSInteger encryptedPayloadLength = INT_MAX;

    self.setDataHeader(ptr, key);
    *(uint32_t *)(ptr + self.headerLength) = htonl(packetId);

    const uint8_t *extra = ptr; // AD = header + peer id + packet id
    if (self.peerId == PacketPeerIdDisabled) {
        extra += self.headerLength; // AD = packet id only
    }

    const BOOL success = [self.crypto encryptBytes:payload
                                            length:payloadLength
                                              dest:(ptr + self.headerLength + PacketIdLength) // skip header and packet id
                                        destLength:&encryptedPayloadLength
                                             extra:extra
                                             error:error];
    
    NSAssert(encryptedPayloadLength <= capacity, @"Did not allocate enough bytes for payload");
    
    if (!success) {
        return nil;
    }
    
    encryptedPacket.length = self.headerLength + PacketIdLength + encryptedPayloadLength;
    return encryptedPacket;
}

#pragma mark DataPathDecrypter

- (BOOL)decryptDataPacket:(NSData *)packet into:(uint8_t *)dest length:(NSInteger *)length packetId:(uint32_t *)packetId error:(NSError *__autoreleasing *)error
{
    const uint8_t *extra = packet.bytes; // AD = header + peer id + packet id
    if (self.peerId == PacketPeerIdDisabled) {
        extra += self.headerLength; // AD = packet id only
    }

    // skip header + packet id
    const BOOL success = [self.crypto decryptBytes:(packet.bytes + self.headerLength + PacketIdLength)
                                            length:(int)(packet.length - (self.headerLength + PacketIdLength))
                                              dest:dest
                                        destLength:length
                                             extra:extra
                                             error:error];
    if (!success) {
        return NO;
    }
    if (self.checkPeerId && !self.checkPeerId(packet.bytes)) {
        if (error) {
            *error = TunnelKitErrorWithCode(TunnelKitErrorCodeDataPathPeerIdMismatch);
        }
        return NO;
    }
    *packetId = ntohl(*(const uint32_t *)(packet.bytes + self.headerLength));
    return YES;
}

- (const uint8_t *)parsePayloadWithDataPacket:(uint8_t *)packet packetLength:(NSInteger)packetLength length:(NSInteger *)length
{
    uint8_t *ptr = packet;
    *length = packetLength - (int)(ptr - packet);
    if (self.compressionFraming != CompressionFramingDisabled) {
        switch (*ptr) {
            case CompressionFramingNoCompress:
                ptr += sizeof(uint8_t);
                break;
                
            case CompressionFramingNoCompressSwap:
                *ptr = packet[packetLength - 1];
                break;
                
            default:
                NSAssert(NO, @"Compression not supported (found %X)", *ptr);
                break;
        }
        *length -= sizeof(uint8_t);
    }
    return ptr;
}

@end
