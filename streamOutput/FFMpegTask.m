//
//  FFMpegTask.m
//  H264Streamer
//
//  Created by Zakk on 9/4/12.
//  Copyright (c) 2012 Zakk. All rights reserved.
//

#import "FFMpegTask.h"
#import <sys/types.h>
#import <sys/stat.h>

#import <stdio.h>

@implementation FFMpegTask


#include "libavformat/avformat.h"

@synthesize stream_output = _stream_output;



int readAudioTagLength(char **buffer)
{
    int length = 0;
    int cnt =4;
    
    while(cnt--)
    {
        int c = *(*buffer)++;
        
        length = (length << 7) | (c & 0x7f);
        if (!(c & 0x80))
            break;
    }
    return length;
}


int readAudioTag(char **buffer, int *tag)
{
    
    *tag = *(*buffer)++;
    return readAudioTagLength(buffer);
    
}



void getAudioExtradata(char *cookie, char **buffer, size_t *size)
{
    char *esds = cookie;
    
    int tag, length;
    
    *size = 0;
    
    readAudioTag(&esds, &tag);
    esds += 2;
    if (tag == 0x03)
        esds++;
    
    readAudioTag(&esds, &tag);
    
    
    if (tag == 0x04) {
        esds++;
        esds++;
        esds += 3;
        esds += 4;
        esds += 4;
        
        length = readAudioTag(&esds, &tag);
        if (tag == 0x05)
        {
            *buffer = calloc(1, length + 8);
            if (*buffer)
            {
                memcpy(*buffer, esds, length);
                *size = length;
                
            }
            
        }
    }
}





-(void) writeAudioSampleBuffer:(CMSampleBufferRef)theBuffer presentationTimeStamp:(CMTime)pts;
{
    CFRetain(theBuffer);

    
    if (_av_audio_stream)
    {
        dispatch_async(_stream_dispatch, ^{
            
            CMBlockBufferRef blockBufferRef = CMSampleBufferGetDataBuffer(theBuffer);
            size_t buffer_length;
            size_t offset_length;
            char *sampledata;
        
        
            AVPacket pkt;
        
            av_init_packet(&pkt);
        
        
            pkt.stream_index = _av_audio_stream->index;
        
            CMBlockBufferGetDataPointer(blockBufferRef, 0, &offset_length, &buffer_length, &sampledata);
        
            pkt.data = (uint8_t *)sampledata;
        
            pkt.size = (int)buffer_length;

            
            pkt.pts = CMTimeGetSeconds(pts)*1000;
         
            if (av_interleaved_write_frame(_av_fmt_ctx, &pkt) < 0)
            {
                NSLog(@"AV WRITE AUDIO failed");
                [self stopProcess];
            }
            //CMSampleBufferInvalidate(theBuffer);
            CFRelease(theBuffer);
        });
    } else if (!_audio_extradata) {
        
        CMAudioFormatDescriptionRef audio_fmt;
        audio_fmt = CMSampleBufferGetFormatDescription(theBuffer);
        void *audio_tmp;
        if (!audio_fmt)
            return;
        
        
        
        audio_tmp = (char *)CMAudioFormatDescriptionGetMagicCookie(audio_fmt, &_audio_extradata_size);
        
        if (audio_tmp)
        {
            getAudioExtradata(audio_tmp, &_audio_extradata, &_audio_extradata_size);
        }
    }
}


-(NSString *)stream_output
{
    return _stream_output;
    
}


-(void) setStream_output:(NSString *)stream_output
{
    _stream_output = stream_output;
    if ([_stream_output hasPrefix:@"rtmp://"])
    {
        self.stream_format = @"FLV";
    }

    
}
-(bool) createAVFormatOut:(CMSampleBufferRef)theBuffer
{
 
    NSLog(@"Creating output format %@ DESTINATION %@", _stream_format, _stream_output);
    AVOutputFormat *av_out_fmt;
    
    
    if (_stream_format) {
        avformat_alloc_output_context2(&_av_fmt_ctx, NULL, [_stream_format UTF8String], [_stream_output UTF8String]);
    } else {
        avformat_alloc_output_context2(&_av_fmt_ctx, NULL, NULL, [_stream_output UTF8String]);
    }
    
    if (!_av_fmt_ctx)
    {
        NSLog(@"No av_fmt_ctx");
        return NO;
    }
    
    
    av_out_fmt = _av_fmt_ctx->oformat;
    _av_video_stream = avformat_new_stream(_av_fmt_ctx, 0);
    
    if (!_av_video_stream)
    {
        NSLog(@"No av_video_stream");
        return NO;
    }
    
    
    AVCodecContext *c_ctx = _av_video_stream->codec;
    
    c_ctx->codec_type = AVMEDIA_TYPE_VIDEO;
    c_ctx->codec_id = AV_CODEC_ID_H264;
    c_ctx->width = _width;
    c_ctx->height = _height;
    c_ctx->time_base.num = 1;
    c_ctx->time_base.den = _framerate;
    
    
    _av_audio_stream = avformat_new_stream(_av_fmt_ctx, 0);
    
    if (!_av_audio_stream)
    {
        NSLog(@"No av_audio_stream");
        return NO;
    }
    
    AVCodecContext *a_ctx = _av_audio_stream->codec;
    
    a_ctx->codec_type = AVMEDIA_TYPE_AUDIO;
    a_ctx->codec_id = AV_CODEC_ID_AAC;
    a_ctx->time_base.num = 1;
    a_ctx->time_base.den = _framerate;
    a_ctx->sample_rate = _samplerate;
    a_ctx->channels = 2;
    a_ctx->extradata = (unsigned char *)_audio_extradata;
    a_ctx->extradata_size = (int)_audio_extradata_size;
    a_ctx->frame_size = (_samplerate * 2 * 2) / _framerate;
    
    CMFormatDescriptionRef fmt;
    CFDictionaryRef atoms;
    CFStringRef avccKey;
    CFDataRef avcc_data;
    CFIndex avcc_size;
    
    fmt = CMSampleBufferGetFormatDescription(theBuffer);
    atoms = CMFormatDescriptionGetExtension(fmt, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    avccKey = CFStringCreateWithCString(NULL, "avcC", kCFStringEncodingUTF8);
    avcc_data = CFDictionaryGetValue(atoms, avccKey);
    avcc_size = CFDataGetLength(avcc_data);
    c_ctx->extradata = malloc(avcc_size);
    
    CFDataGetBytes(avcc_data, CFRangeMake(0,avcc_size), c_ctx->extradata);
    
    c_ctx->extradata_size = (int)avcc_size;
    
    if (_av_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
        c_ctx->flags |= CODEC_FLAG_GLOBAL_HEADER;
  
    if (_av_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
        a_ctx->flags |= CODEC_FLAG_GLOBAL_HEADER;

    
    av_dump_format(_av_fmt_ctx, 0, [_stream_output UTF8String], 1);
    
    if (!(av_out_fmt->flags & AVFMT_NOFILE))
    {
        NSLog(@"Doing AVIO_OPEN");
        if (avio_open(&_av_fmt_ctx->pb, [_stream_output UTF8String], AVIO_FLAG_WRITE) < 0)
        {
            NSLog(@"AVIO_OPEN failed");
            [self stopProcess];
        }
    }
    
    if (avformat_write_header(_av_fmt_ctx, NULL) < 0)
    {
        NSLog(@"AVFORMAT_WRITE_HEADER failed");
        [self stopProcess];
    }
    return YES;
}


-(void) writeVideoSampleBuffer:(CMSampleBufferRef)theBuffer
{
    
    
    CFRetain(theBuffer);
    
    if (!_stream_dispatch)
    {
       _stream_dispatch = dispatch_queue_create("FFMpeg Stream Dispatch", NULL);
    }
    
    
    dispatch_async(_stream_dispatch, ^{
        
    if (!_av_video_stream)
    {
        if (_audio_extradata)
        {
            [self createAVFormatOut:theBuffer];
        } else {
            return;
        }
    }
    CMBlockBufferRef my_buffer;
    char *sampledata;
    size_t offset_length;
    size_t buffer_length;
    
    my_buffer = CMSampleBufferGetDataBuffer(theBuffer);
    
    
    AVPacket pkt;
    
    av_init_packet(&pkt);
    
    
    pkt.stream_index = _av_video_stream->index;
    
    CMBlockBufferGetDataPointer(my_buffer, 0, &offset_length, &buffer_length, &sampledata);
    
    pkt.data = (uint8_t *)sampledata;
    
    pkt.size = (int)buffer_length;
    
        
    pkt.pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(theBuffer))*1000;
        
        
        
    if ([self isBufferKeyframe:theBuffer])
    {
        pkt.flags |= AV_PKT_FLAG_KEY;
    }
    
    
        
    if (av_interleaved_write_frame(_av_fmt_ctx, &pkt) < 0)
    {
        NSLog(@"VIDEO WRITE FRAME failed");
        [self stopProcess];
    }
    
    //CMSampleBufferInvalidate(theBuffer);
    CFRelease(theBuffer);
        
    });
    
    return;
        
  }


-(BOOL) isBufferKeyframe:(CMSampleBufferRef)theBuffer
{
    
    CFArrayRef sample_attachments;
    BOOL result = NO;
    
    sample_attachments = CMSampleBufferGetSampleAttachmentsArray(theBuffer, NO);
    if (sample_attachments)
    {
        CFDictionaryRef attach;
        CFBooleanRef depends_on_others;
        
        attach = CFArrayGetValueAtIndex(sample_attachments, 0);
        depends_on_others = CFDictionaryGetValue(attach, kCMSampleAttachmentKey_DependsOnOthers);
        result = depends_on_others == kCFBooleanFalse;
    }
    
    return result;
    
}



-(id)init
{
    
    self = [super init];
    
    av_register_all();
    avformat_network_init();
    
    
    _stream_dispatch = dispatch_queue_create("FFMpeg Stream Dispatch", NULL);
    
    
    return self;
    
}


-(bool)stopProcess
{
    if (_av_fmt_ctx)
    {
        av_write_trailer(_av_fmt_ctx);
        avio_close(_av_fmt_ctx->pb);
        av_free(_av_fmt_ctx);
    }
    
    if (_av_video_stream)
        av_free(_av_video_stream);
    if (_av_audio_stream)
        av_free(_av_audio_stream);

    _av_fmt_ctx = NULL;
    _av_video_stream = NULL;
    _av_audio_stream = NULL;
    
    
    _stream_dispatch = nil;
    return YES;
}
@end
