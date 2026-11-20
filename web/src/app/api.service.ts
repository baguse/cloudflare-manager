import { Injectable, signal, computed } from '@angular/core';

export interface CloudflaredInfo {
  installed: boolean;
  path?: string | null;
  version?: string | null;
}

@Injectable({ providedIn: 'root' })
export class ApiService {
  private _url = signal(localStorage.getItem('cf_url') || '');
  private _key = signal(localStorage.getItem('cf_key') || '');
  private _baseUrl = window.location.origin || '';
  private _ws: WebSocket | null = null;
  private _wsRetries = 0;
  private _wsMaxRetries = 10;
  private _eventSeq = signal(0);
  readonly eventCount = this._eventSeq.asReadonly();
  readonly cloudflared = signal<CloudflaredInfo | null>(null);
  readonly daemonRunning = signal<boolean>(true);

  get configured() { return !!this._url() && !!this._key(); }
  get apiUrl() { return this._url(); }
  get apiKey() { return this._key(); }

  connect(url: string, key: string) {
    this._url.set(url); this._key.set(key);
    localStorage.setItem('cf_url', url); localStorage.setItem('cf_key', key);
    this.startWs();
    this.checkCloudflared();
  }

  setKey(key: string) { this._key.set(key); }
  clearKey() { this._key.set(''); }

  disconnect() {
    this._ws?.close(); this._ws = null;
    this._url.set(''); this._key.set('');
    this.cloudflared.set(null);
    localStorage.removeItem('cf_url'); localStorage.removeItem('cf_key');
  }

  startWs() { this._startWs(); }

  async checkCloudflared(refresh = false): Promise<CloudflaredInfo> {
    try {
      const res = await this.call(`/api/cloudflared${refresh ? '?refresh=true' : ''}`, 'GET');
      if (res && typeof res.installed === 'boolean') {
        const info: CloudflaredInfo = {
          installed: res.installed,
          path: res.path || null,
          version: res.version || null,
        };
        this.cloudflared.set(info);
        return info;
      }
    } catch {}
    const fallback: CloudflaredInfo = { installed: false, path: null, version: null };
    this.cloudflared.set(fallback);
    return fallback;
  }

  async call(path: string, method = 'GET', data?: any): Promise<any> {
    const base = this._url() || localStorage.getItem('cf_url') || this._baseUrl;
    const url = base!.replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + this._key() };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    const json = await res.json();
    if (json && json.cloudflared && typeof json.cloudflared.installed === 'boolean') {
      this.cloudflared.set(json.cloudflared);
    }
    if (json && typeof json.daemonRunning === 'boolean') {
      this.daemonRunning.set(json.daemonRunning);
    } else if (json && typeof json.running === 'boolean') {
      this.daemonRunning.set(json.running);
    }
    return json;
  }

  async callWithKey(key: string, path: string, method = 'GET', data?: any): Promise<any> {
    const base = this._url() || localStorage.getItem('cf_url') || this._baseUrl;
    const url = base!.replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + key };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    const json = await res.json();
    if (json && json.cloudflared && typeof json.cloudflared.installed === 'boolean') {
      this.cloudflared.set(json.cloudflared);
    }
    if (json && typeof json.daemonRunning === 'boolean') {
      this.daemonRunning.set(json.daemonRunning);
    } else if (json && typeof json.running === 'boolean') {
      this.daemonRunning.set(json.running);
    }
    return json;
  }

  async toggleTunnelService(tunnelId: string, enabled: boolean, port?: number, hostname?: string): Promise<any> {
    return await this.call('/api/tunnels/' + encodeURIComponent(tunnelId) + '/service', 'PUT', { enabled, port, hostname });
  }

  private _startWs() {
    if (!this._key()) return;
    this._ws?.close();
    const base = (this._url() || this._baseUrl).replace(/^http/, 'ws').replace(/\/$/, '');
    try {
      this._ws = new WebSocket(base + '/api/ws?token=' + encodeURIComponent(this._key()));
      this._ws.onopen = () => { console.log('[ws] connected'); this._wsRetries = 0; };
      this._ws.onmessage = (e) => {
        try { JSON.parse(e.data); this._eventSeq.set(this._eventSeq() + 1); } catch {}
      };
      this._ws.onclose = (e) => {
        if (this._wsRetries >= this._wsMaxRetries) return;
        this._wsRetries++;
        const delay = Math.min(1000 * Math.pow(2, this._wsRetries), 30000);
        setTimeout(() => this._startWs(), delay);
      };
      this._ws.onerror = () => this._ws?.close();
    } catch(e) { console.log('[ws] error', e); }
  }
}
