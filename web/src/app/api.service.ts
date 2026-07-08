import { Injectable, signal, computed } from '@angular/core';

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

  get configured() { return !!this._url() && !!this._key(); }
  get apiUrl() { return this._url(); }
  get apiKey() { return this._key(); }

  connect(url: string, key: string) {
    this._url.set(url); this._key.set(key);
    localStorage.setItem('cf_url', url); localStorage.setItem('cf_key', key);
    this.startWs();
  }

  setKey(key: string) { this._key.set(key); }
  clearKey() { this._key.set(''); }

  disconnect() {
    this._ws?.close(); this._ws = null;
    this._url.set(''); this._key.set('');
    localStorage.removeItem('cf_url'); localStorage.removeItem('cf_key');
  }

  startWs() { this._startWs(); }

  async call(path: string, method = 'GET', data?: any): Promise<any> {
    const base = this._url() || localStorage.getItem('cf_url') || this._baseUrl;
    const url = base!.replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + this._key() };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    return res.json();
  }

  async callWithKey(key: string, path: string, method = 'GET', data?: any): Promise<any> {
    const base = this._url() || localStorage.getItem('cf_url') || this._baseUrl;
    const url = base!.replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + key };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    return res.json();
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
