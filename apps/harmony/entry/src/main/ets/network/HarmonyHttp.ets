/**
 * 鸿蒙 HTTP adapter（基于 @kit.NetworkKit 的 http 模块）。
 *
 * 供 auth（登录/刷新）、device-link REST 视图、图片上传等模块消费。
 * 仅支持 JSON 文本请求/响应；二进制上传（图片）后续在 attachments 模块
 * 里单独实现（fileUpload 或带 body 的 request）。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { safeErrorMessage } from '../core/tasks/TaskModels';

const DOMAIN = 0x0000;
const TAG = 'CindyHttp';

export interface HttpResponseData {
  statusCode: number;
  body: string;
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export class HarmonyHttp {
  /** 发起 JSON 请求。headers 已含 Content-Type 时不再追加。 */
  requestJson(
    url: string,
    method: HttpMethod,
    headers: Record<string, string>,
    body?: string,
    timeoutMs?: number,
  ): Promise<HttpResponseData> {
    return new Promise<HttpResponseData>((resolve, reject) => {
      const req = http.createHttp();
      const requestMethod = this.toRequestMethod(method);
      const finalHeaders: Record<string, string> = {};
      const headerKeys = Object.keys(headers);
      for (let i = 0; i < headerKeys.length; i++) {
        finalHeaders[headerKeys[i]] = headers[headerKeys[i]];
      }
      if (body !== undefined && !this.hasContentType(finalHeaders)) {
        finalHeaders['Content-Type'] = 'application/json';
      }
      const options: http.HttpRequestOptions = {
        method: requestMethod,
        header: finalHeaders,
        extraData: body,
        connectTimeout: timeoutMs ?? 15000,
        readTimeout: timeoutMs ?? 15000,
        expectDataType: http.HttpDataType.STRING,
      };
      req.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          hilog.error(DOMAIN, TAG, '%{public}s %{public}s failed: %{public}s',
            method, url, safeErrorMessage(err));
          reject(new Error(`${method} ${url}: ${err.message}`));
          return;
        }
        const raw = data.result;
        let bodyText = '';
        if (typeof raw === 'string') {
          bodyText = raw;
        } else if (raw instanceof ArrayBuffer) {
          const decoder = util.TextDecoder.create('utf-8');
          bodyText = decoder.decodeToString(new Uint8Array(raw));
        } else {
          bodyText = JSON.stringify(raw);
        }
        resolve({
          statusCode: data.responseCode,
          body: bodyText,
        });
      });
    });
  }

  private hasContentType(headers: Record<string, string>): boolean {
    const keys = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === 'content-type') {
        return true;
      }
    }
    return false;
  }

  private toRequestMethod(method: HttpMethod): http.RequestMethod {
    switch (method) {
      case 'GET':
        return http.RequestMethod.GET;
      case 'POST':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'PATCH':
        return http.RequestMethod.PATCH;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      default:
        return http.RequestMethod.GET;
    }
  }

  /** 上传二进制（PUT/POST），返回状态码（OSS 预签名上传用）。 */
  uploadBytes(
    url: string,
    method: HttpMethod,
    headers: Record<string, string>,
    body: ArrayBuffer,
    timeoutMs?: number,
  ): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const req = http.createHttp();
      const finalHeaders: Record<string, string> = {};
      const headerKeys = Object.keys(headers);
      for (let i = 0; i < headerKeys.length; i++) {
        finalHeaders[headerKeys[i]] = headers[headerKeys[i]];
      }
      const options: http.HttpRequestOptions = {
        method: this.toRequestMethod(method),
        header: finalHeaders,
        extraData: body,
        connectTimeout: timeoutMs ?? 60000,
        readTimeout: timeoutMs ?? 120000,
      };
      req.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(new Error(`upload ${url}: ${err.message}`));
          return;
        }
        resolve(data.responseCode);
      });
    });
  }

  /** 下载二进制内容（远端文件预览 / 系统分享临时文件）。 */
  downloadBytes(url: string, timeoutMs?: number): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const req = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs ?? 15000,
        readTimeout: timeoutMs ?? 120000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      req.request(url, options, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(new Error(`download failed: ${err.message}`));
          return;
        }
        if (data.responseCode < 200 || data.responseCode >= 300) {
          reject(new Error(`download failed: HTTP ${data.responseCode}`));
          return;
        }
        if (!(data.result instanceof ArrayBuffer)) {
          reject(new Error('download failed: invalid response'));
          return;
        }
        resolve(data.result);
      });
    });
  }
}
