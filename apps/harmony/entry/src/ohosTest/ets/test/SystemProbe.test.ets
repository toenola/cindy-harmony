/**
 * 切片 0 系统能力验证测试（跑在真机/模拟器）。
 *
 * 运行前把下面的 PROBE_WS_URL 换成你自己的 Device Link relay wss 地址
 * （或任意支持自定义 Header 的 wss 端点），把 PROBE_HTTP_URL 换成
 * 可达的 https 端点。跑完把结果记录到 docs/decision-log.md。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { SystemProbe } from '../../main/ets/core/dev/SystemProbe';

const DOMAIN = 0x0000;
const TAG = 'CindyProbeTest';

// TODO(切片0): 替换为真实 relay 地址与测试 token，验证后从测试中移除 token。
const PROBE_WS_URL = 'wss://YOUR_RELAY_HERE';
const PROBE_WS_HEADERS: Record<string, string> = {
  Authorization: 'Bearer YOUR_TEST_TOKEN',
};
const PROBE_HTTP_URL = 'https://YOUR_HTTPS_ENDPOINT_HERE';
const PROBE_TIMEOUT_MS = 10000;

export default function systemProbeTest() {
  beforeAll(() => {
    hilog.info(DOMAIN, TAG, 'system probe suite start');
  });

  it('probe_ws_wss_custom_header', 0, async () => {
    const ok = await SystemProbe.probeWs(PROBE_WS_URL, PROBE_WS_HEADERS, PROBE_TIMEOUT_MS);
    expect(ok).assertTrue();
  });

  it('probe_http_json_tls', 0, async () => {
    const ok = await SystemProbe.probeHttp(PROBE_HTTP_URL, PROBE_TIMEOUT_MS);
    expect(ok).assertTrue();
  });

  it('probe_storage_write_read_remove', 0, async () => {
    const context = getContext(this);
    const ok = await SystemProbe.probeStorage(context);
    expect(ok).assertTrue();
  });
}
