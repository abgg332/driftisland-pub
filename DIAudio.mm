/* =====================================================================
   DriftIsland 3.0.47 —— 音频频谱采样端(注入 mediaserverd)

   3.0.45/46 只算 RMS(两个 float), 所以环只能"整圈一起亮", 怎么画都不像
   参考视频里那种长短起伏的刻度。3.0.47 升级成真频谱:

     1. MSHookFunction 包一层 AudioUnitRender, 把系统最终混音的样本混成
        单声道推进环形缓冲(只读, 一个字节都不改);
     2. 独立线程每 16ms 取最近 1024 点做 Hann 加窗 FFT(自写 radix-2,
        不引 Accelerate, 避免 mediaserverd 里额外依赖), 归成 24 段对数频带
        (60Hz~14kHz), 每段做慢衰减 AGC + 快起慢落包络, 输出 0~255;
     3. 127.0.0.1:41235 推 36 字节定长包:
        [0]=0xD7 [1]=版本 [2]=段数 [3]=保留 [4..7]=fast [8..11]=slow
        [12..35]=24 段频谱。暂停/没歌时渲染的是静音 → 频谱自然归零。

   没有写文件/改配置。卸载插件后 substrate 不再注入, mediaserverd 恢复原样。
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

#define DI_AU_PORT   41235
#define DI_FFT_N     1024
#define DI_BANDS     24
#define DI_RING      (DI_FFT_N * 4)

static double gDIFast = 0.0;      /* 快包络: ~50ms 跟手 */
static double gDISlow = 0.0;      /* 慢包络: ~2s 底噪/平均响度 */
static CFAbsoluteTime gDIStamp = 0;
static double gDISampleRate = 44100.0;
static int gDISawFormat = 0;

/* ---------- 采样环形缓冲 ---------- */
static float gDIRing[DI_RING];
static int   gDIRingW = 0;
static volatile uint32_t gDIRingFill = 0;

/* ---------- FFT 预计算 ---------- */
static float gDIWin[DI_FFT_N];
static float gDICosT[DI_FFT_N / 2];
static float gDISinT[DI_FFT_N / 2];
static int   gDIBitrev[DI_FFT_N];
static float gDIRe[DI_FFT_N], gDIIm[DI_FFT_N];
static BOOL  gDIFFTReady = NO;

/* ---------- 频带 ---------- */
static uint8_t gDIBandByte[DI_BANDS];
static float gDIBandF[DI_BANDS];
static float gDIBandPeak[DI_BANDS];
static int   gDIBandLo[DI_BANDS], gDIBandHi[DI_BANDS];

/* ================= 3.0.71: 底鼓("咚")在**样本域**上抓 =================
   481 用户: "粒子跟专辑头像的鼓点还是差点意思, 没有视频的效果节点";
   482 用户还给了参考实现(FlexMusicAudioBridge) —— 它就是注入 mediaserverd
   钩 AudioUnitRender 拿原始 PCM。我们的 DIAudio 走的同一条路, 所以不用再
   拿 24 段(每段 16ms 的 FFT 结果)去做二次差分: 那种做法一包里可能已经漏掉
   了起音前沿, 客户端再 40Hz 采样, 拍点必然"飘"。
   这里每个 render 回调(≈10~23ms)对混音做一次 110Hz 二阶低通 + RMS, 直接抓
   低频能量的上升沿 —— 和视频里"每一个咚都落在节点上"是同一种数据。 */
static float gDILp1 = 0.0f, gDILp2 = 0.0f;       /* 两级一阶低通(≈110Hz) */
static double gDILowAcc = 0.0;
static int    gDILowAccN = 0;
static double gDILowEnv = 0.0;                   /* 低频包络(线性) */
static double gDIBase = 0.0;                     /* 底噪慢跟随 */
static double gDIPrevEnv = 0.0;
static double gDILastKick = 0.0;
static BOOL   gDIKickArmed = YES;
static volatile float    gDIKickAmp = 0.0f;      /* 0~1: 这一下的强度 */
static volatile uint32_t gDIKickSerial = 0;      /* 每触发一次 +1, 客户端据此判新鼓点 */
static volatile double   gDIKickStamp = 0.0;     /* 触发时刻(CFAbsoluteTime) */
static volatile float    gDILowRms = 0.0f;

static void diFFTPrepare(void) {
    if (gDIFFTReady) return;
    const int bits = 10;                        /* log2(1024) */
    for (int i = 0; i < DI_FFT_N; i++) {
        gDIWin[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * (float)i / (float)(DI_FFT_N - 1));
        int r = 0;
        for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
        gDIBitrev[i] = r;
    }
    for (int i = 0; i < DI_FFT_N / 2; i++) {
        gDICosT[i] = cosf(2.0f * (float)M_PI * (float)i / (float)DI_FFT_N);
        gDISinT[i] = sinf(2.0f * (float)M_PI * (float)i / (float)DI_FFT_N);
    }
    /* 24 段对数频带 60Hz ~ 14kHz */
    double f0 = 60.0, f1 = 14000.0;
    for (int b = 0; b < DI_BANDS; b++) {
        double lo = f0 * pow(f1 / f0, (double)b / DI_BANDS);
        double hi = f0 * pow(f1 / f0, (double)(b + 1) / DI_BANDS);
        int k0 = (int)floor(lo / gDISampleRate * DI_FFT_N);
        int k1 = (int)ceil(hi / gDISampleRate * DI_FFT_N);
        if (k0 < 1) k0 = 1;
        if (k1 <= k0) k1 = k0 + 1;
        if (k1 > DI_FFT_N / 2 - 1) k1 = DI_FFT_N / 2 - 1;
        gDIBandLo[b] = k0;
        gDIBandHi[b] = k1;
    }
    for (int b = 0; b < DI_BANDS; b++) { gDIBandF[b] = 0; gDIBandPeak[b] = 0.25f; }
    gDIFFTReady = YES;
}

static void diFFT(float *re, float *im) {
    for (int i = 0; i < DI_FFT_N; i++) {
        int j = gDIBitrev[i];
        if (j > i) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= DI_FFT_N; len <<= 1) {
        int half = len >> 1, step = DI_FFT_N / len;
        for (int i = 0; i < DI_FFT_N; i += len) {
            for (int k = 0; k < half; k++) {
                float wr = gDICosT[k * step], wi = -gDISinT[k * step];
                int a = i + k, b = a + half;
                float tr = re[b] * wr - im[b] * wi;
                float ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr;        im[a] += ti;
            }
        }
    }
}

/* 取最近 1024 点算一遍频谱, 结果写进 gDIBandByte */
static BOOL diComputeBands(void) {
    diFFTPrepare();
    if (gDIRingFill < DI_FFT_N) return NO;
    int start = (gDIRingW - DI_FFT_N + DI_RING * 2) % DI_RING;
    float energy = 0;
    for (int i = 0; i < DI_FFT_N; i++) {
        float v = gDIRing[(start + i) % DI_RING];
        energy += v * v;
        gDIRe[i] = v * gDIWin[i];
        gDIIm[i] = 0.0f;
    }
    if (sqrtf(energy / DI_FFT_N) < 1e-5f) {          /* 静音: 快速归零 */
        for (int b = 0; b < DI_BANDS; b++) {
            gDIBandF[b] *= 0.55f;
            gDIBandByte[b] = (uint8_t)(gDIBandF[b] * 255.0f);
            gDIBandPeak[b] = MAX(0.25f, gDIBandPeak[b] * 0.985f);
        }
        return YES;
    }
    diFFT(gDIRe, gDIIm);
    for (int b = 0; b < DI_BANDS; b++) {
        float mag = 0.0f;
        for (int k = gDIBandLo[b]; k <= gDIBandHi[b]; k++) {
            if (k < 1 || k > DI_FFT_N / 2 - 1) continue;
            float m = sqrtf(gDIRe[k] * gDIRe[k] + gDIIm[k] * gDIIm[k]);
            if (m > mag) mag = m;
        }
        float amp = 4.0f * mag / (float)DI_FFT_N;     /* Hann 相干增益 0.5 */
        float db = 20.0f * log10f(amp + 1e-9f);
        float v = (db + 62.0f) / 54.0f;               /* -62dB → 0, -8dB → 1 */
        if (v < 0) v = 0;
        if (v > 1) v = 1;
        /* 3.0.57: 不再做"归一到自身峰值"的 AGC。
           旧版 out = 0.45v + 0.55(v/peak): 音乐一起来 peak 立刻贴到 1, 于是 v/peak 恒等于 1,
           out 就被钉在 0.55 + 0.45v ≈ 0.85 —— 客户端探针日志里"中音"60 行全在 0.84~0.90,
           一帧之内的上冲(谱通量)几乎为 0, 所以鼓点检测一直是 0.00, 封面/粒子都不动。
           现在直接送 dB 归一后的绝对值 v; 包络、平滑、AGC 全部交给客户端(那边按 dt 做,
           120Hz 下才顺), 这样"这一包比上一包突然高了"才是真实的。 */
        gDIBandF[b] = v;
        gDIBandByte[b] = (uint8_t)(v * 255.0f);
    }
    return YES;
}

static OSStatus (*gDIOrigRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                 const AudioTimeStamp *, UInt32, UInt32,
                                 AudioBufferList *) = NULL;

static void diPushSamples(const float *p, int n, int stride) {
    /* 3.0.71: 边推环形缓冲边算"底鼓频段"能量 —— 110Hz 两级一阶低通,
       输出平方累加, 每个 render 回调清一次(见 diKickDetect)。 */
    double a = exp(-2.0 * M_PI * 110.0 / MAX(8000.0, gDISampleRate));
    for (int i = 0; i < n; i++) {
        float v = p[i * stride];
        gDIRing[gDIRingW] = v;
        gDIRingW = (gDIRingW + 1) % DI_RING;
        float f1 = (float)((1.0 - a) * v + a * gDILp1); gDILp1 = f1;
        float f2 = (float)((1.0 - a) * f1 + a * gDILp2); gDILp2 = f2;
        gDILowAcc += (double)f2 * (double)f2;
        gDILowAccN++;
    }
    uint32_t f = gDIRingFill + (uint32_t)n;
    gDIRingFill = (f > DI_RING) ? DI_RING : f;
}

/* 3.0.71: 一个回调算一次 —— 低频 RMS → 包络 → 起音判定。
   · 起音(attack): 这一块的 RMS 比上一块冲出去多少(不需要额外平滑, 块本身
     就是 10~23ms 的窗口, 再平滑就把前沿抹掉了);
   · 底噪(base): 掉下去立刻跟, 往上 2s 慢爬 —— 自适应, 每首歌/每段响度都成立;
   · 只响一次: 触发后必须掉回底噪 1.35 倍以内才重新上膛, 鼓身余音不会顶第二下;
   · 不应期 0.12s: 再快的连击也不会糊成一片。 */
static void diKickDetect(double blockSec) {
    if (gDILowAccN <= 0) return;
    float lowR = (float)sqrt(gDILowAcc / (double)gDILowAccN);
    gDILowAcc = 0.0; gDILowAccN = 0;
    gDILowRms = lowR;

    double env = (double)lowR;
    if (env > gDILowEnv) gDILowEnv = env;                                  /* 起音立刻跟上 */
    else gDILowEnv += (env - gDILowEnv) * (1.0 - exp(-MAX(0.001, blockSec) / 0.10));

    if (gDIBase <= 1e-5) gDIBase = gDILowEnv * 0.60;
    if (gDILowEnv < gDIBase) gDIBase += (gDILowEnv - gDIBase) * 0.35;
    else gDIBase += (gDILowEnv - gDIBase) * (1.0 - exp(-MAX(0.001, blockSec) / 2.0));
    if (gDIBase < 1e-5) gDIBase = 1e-5;

    double prev = gDIPrevEnv;
    gDIPrevEnv = gDILowEnv;
    double delta = gDILowEnv - prev;
    double ratio = gDILowEnv / gDIBase;
    double now = CFAbsoluteTimeGetCurrent();

    if (gDILowEnv < gDIBase * 1.35) gDIKickArmed = YES;

    if (gDIKickArmed && gDILowEnv > 0.0035 && ratio > 1.80 &&
        delta > gDIBase * 0.50 && (now - gDILastKick) > 0.12) {
        float amp = (float)(0.42 + 0.32 * log2(1.0 + ratio));
        if (amp > 1.0f) amp = 1.0f;
        if (amp < 0.35f) amp = 0.35f;
        gDIKickAmp = amp;
        gDIKickStamp = now;
        gDIKickSerial = gDIKickSerial + 1;
        gDILastKick = now;
        gDIKickArmed = NO;
    }
}

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
        if (!b->mData || b->mDataByteSize < 64) return r;
        int ch = (int)b->mNumberChannels;
        if (ch < 1) ch = 1;
        double rms = -1.0;
        int nf = (int)(b->mDataByteSize / 4);
        if (nf > 8) {
            float *p = (float *)b->mData;
            int ok = 1;
            double sum = 0.0;
            for (int i = 0; i < nf; i++) {
                float v = p[i];
                if (!isfinite(v) || fabsf(v) > 8.0f) { ok = 0; break; }
                sum += (double)v * (double)v;
            }
            if (ok) {
                rms = sqrt(sum / (double)nf);
                /* 推到环形缓冲做 FFT: 多声道取交织后的第一声道即可 */
                int frames = nf / ch;
                if (frames > 0) {
                    diPushSamples(p, frames, ch);
                    /* 3.0.71: 每个回调抓一次"咚"(样本域, 见 diKickDetect) */
                    diKickDetect((double)frames / MAX(8000.0, gDISampleRate));
                }
                if (!gDISawFormat) {
                    gDISawFormat = 1;
                    AudioStreamBasicDescription asbd;
                    UInt32 sz = sizeof asbd;
                    if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Output, 0, &asbd, &sz) == noErr
                        && asbd.mSampleRate > 8000) {
                        gDISampleRate = asbd.mSampleRate;
                        gDIFFTReady = NO;   /* 用真实采样率重算频带 */
                        diFFTPrepare();
                    }
                }
            }
        }
        if (rms < 0.0) {                                  /* int16 兜底 */
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
        for (;;) {
            /* 3.0.55: 33ms → 16ms。30Hz 的数据在 120Hz 屏上就是"每四帧才变一次",
               刻度和粒子再怎么平滑也是顿的。60Hz 发包, 32 字节/包, 开销可以忽略。 */
            usleep(16000);
            BOOL live = (CFAbsoluteTimeGetCurrent() - gDIStamp < 0.5);
            float fast = 0.0f, slow = 0.0f;
            uint8_t bands[DI_BANDS];
            if (live) {
                diComputeBands();
                fast = (float)gDIFast;
                slow = (float)gDISlow;
                memcpy(bands, gDIBandByte, DI_BANDS);
            } else {
                memset(bands, 0, sizeof bands);
                for (int b = 0; b < DI_BANDS; b++) gDIBandF[b] *= 0.6f;
            }
            uint8_t pkt[48];
            memset(pkt, 0, sizeof pkt);
            pkt[0] = 0xD7;
            pkt[1] = 2;                    /* 3.0.71: 协议 v2 —— 多了"咚"的字段 */
            pkt[2] = DI_BANDS;
            pkt[3] = 0;
            memcpy(pkt + 4, &fast, 4);
            memcpy(pkt + 8, &slow, 4);
            memcpy(pkt + 12, bands, DI_BANDS);
            /* [36] 强度 [38..39] 距触发多少 ms [40..43] 触发序号 [44..47] 低频 RMS */
            float kamp = live ? gDIKickAmp : 0.0f;
            pkt[36] = (uint8_t)(MAX(0.0f, MIN(1.0f, kamp)) * 255.0f);
            double ageMs = (CFAbsoluteTimeGetCurrent() - gDIKickStamp) * 1000.0;
            if (ageMs < 0) ageMs = 0;
            if (ageMs > 60000.0) ageMs = 60000.0;
            uint16_t age = (uint16_t)ageMs;
            memcpy(pkt + 38, &age, 2);
            uint32_t serial = gDIKickSerial;
            memcpy(pkt + 40, &serial, 4);
            float lowR = live ? gDILowRms : 0.0f;
            memcpy(pkt + 44, &lowR, 4);
            ssize_t n = send(c, pkt, sizeof pkt, MSG_NOSIGNAL);
            if (n != (ssize_t)sizeof pkt) break;
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
    NSLog(@"[DriftIsland] 频谱采样已启动 (mediaserverd, 127.0.0.1:%d, FFT %d 点/%d 段)",
          DI_AU_PORT, DI_FFT_N, DI_BANDS);
}
