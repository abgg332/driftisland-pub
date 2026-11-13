/* =====================================================================
   DriftIsland 3.0.45 —— 音频能量采样端(注入 mediaserverd)

   只做三件事:
     1. MSHookFunction 包一层 AudioUnitRender, 对系统最终混音算 RMS 能量
        (快/慢两条包络), 不改音频数据;
     2. 起一个 127.0.0.1:41235 的本地 socket 服务, 每 33ms 推送一次
        {float fast, float slow} 共 8 字节 —— 暂停/没歌时渲染的就是静音,
        RMS 自然归零, 对端粒子自动熄灭;
     3. 没有任何写文件/改配置动作。卸载插件后 substrate 不再注入本 dylib,
        mediaserverd 恢复原样(hook 只包一层转发, 不碰缓冲区内容)。

   参考 FlexMusic 的做法(AudioUnitRender + loopback socket), 协议是我们
   自己的 8 字节定长包, 端口 41235 与它不冲突, 两装互不影响。
   注意: 本文件是 .mm, 不走 Logos 预处理, hook 手写 MSHookFunction。
   ===================================================================== */
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/errno.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <math.h>
#import <pthread.h>

#define DI_AU_PORT 41235

static double gDIFast = 0.0;      /* 快包络: ~50ms 跟手 */
static double gDISlow = 0.0;      /* 慢包络: ~2s 底噪/平均响度 */
static CFAbsoluteTime gDIStamp = 0;

static OSStatus (*gDIOrigRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                 const AudioTimeStamp *, UInt32, UInt32,
                                 AudioBufferList *) = NULL;

static OSStatus diAudioRenderHook(AudioUnit inUnit,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber, UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    OSStatus r = gDIOrigRender ? gDIOrigRender(inUnit, ioActionFlags, inTimeStamp,
                                               inBusNumber, inNumberFrames, ioData)
                               : AudioUnitRender(inUnit, ioActionFlags, inTimeStamp,
                                                 inBusNumber, inNumberFrames, ioData);
    if (r == noErr && ioData && ioData->mNumberBuffers > 0 && inNumberFrames > 0) {
        AudioBuffer *b = &ioData->mBuffers[0];
        if (b->mData && b->mDataByteSize >= 64) {
            double rms = -1.0;
            /* 输出混音几乎总是 float32; 逐样本做合法性检查, 不像就退回 int16 */
            int nf = (int)(b->mDataByteSize / 4);
            if (nf > 0) {
                float *p = (float *)b->mData;
                double sum = 0.0;
                int ok = 1;
                for (int i = 0; i < nf; i++) {
                    float v = p[i];
                    if (!isfinite(v) || fabsf(v) > 8.0f) { ok = 0; break; }
                    sum += (double)v * (double)v;
                }
                if (ok) rms = sqrt(sum / (double)nf);
            }
            if (rms < 0.0) {
                int n16 = (int)(b->mDataByteSize / 2);
                if (n16 > 0) {
                    int16_t *q = (int16_t *)b->mData;
                    double sum = 0.0;
                    for (int i = 0; i < n16; i++) sum += (double)q[i] * (double)q[i];
                    rms = sqrt(sum / (double)n16) / 32768.0;
                }
            }
            if (rms >= 0.0 && rms <= 2.0) {
                gDIFast = gDIFast * 0.45 + rms * 0.55;
                gDISlow = gDISlow * 0.985 + rms * 0.015;
                gDIStamp = CFAbsoluteTimeGetCurrent();
            }
        }
    }
    return r;
}

static void *diAudioServerThread(void *arg) {
    (void)arg;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NULL;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(DI_AU_PORT);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return NULL; }
    if (listen(s, 2) != 0) { close(s); return NULL; }
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        int nb = fcntl(c, F_GETFL, 0);
        if (nb >= 0) fcntl(c, F_SETFL, nb | O_NONBLOCK);
        /* 客户端连上后永久推流; 客户端断开(send 报错)就关掉等下一个连接 */
        for (;;) {
            usleep(33000);
            float fast = 0.0f, slow = 0.0f;
            if (CFAbsoluteTimeGetCurrent() - gDIStamp < 0.5) {
                fast = (float)gDIFast;
                slow = (float)gDISlow;
            }
            uint8_t pkt[8];
            memcpy(pkt, &fast, 4);
            memcpy(pkt + 4, &slow, 4);
            ssize_t n = send(c, pkt, 8, MSG_NOSIGNAL);
            if (n != 8) break;
        }
        close(c);
    }
    return NULL;
}

__attribute__((constructor)) static void diAudioInit(void) {
    MSHookFunction((void *)AudioUnitRender, (void *)diAudioRenderHook,
                   (void **)&gDIOrigRender);
    pthread_t t;
    if (pthread_create(&t, NULL, diAudioServerThread, NULL) == 0) pthread_detach(t);
    NSLog(@"[DriftIsland] 音频能量采样已启动 (mediaserverd, 127.0.0.1:%d)", DI_AU_PORT);
}
