import { Injectable, signal, computed } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ApiService {
  private _url = signal(localStorage.getItem('cf_url') || '');
  private _key = signal(localStorage.getItem('cf_key') || '');
  private _ws: WebSocket | null = null;
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

  disconnect() {
    this._ws?.close(); this._ws = null;
    this._url.set(''); this._key.set('');
    localStorage.removeItem('cf_url'); localStorage.removeItem('cf_key');
  }

  startWs() { this._startWs(); }

  async call(path: string, method = 'GET', data?: any): Promise<any> {
    const url = this._url().replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + this._key() };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    return res.json();
  }

  private _startWs() {
    if (!this.configured) return;
    this._ws?.close();
    const base = this._url().replace(/^http/, 'ws').replace(/\/$/, '');
    try {
      this._ws = new WebSocket(base + '/api/ws?token=' + encodeURIComponent(this._key()));
      this._ws.onopen = () => console.log('[ws] connected');
      this._ws.onmessage = (e) => {
        try { JSON.parse(e.data); this._eventSeq.set(this._eventSeq() + 1); } catch {}
      };
      this._ws.onclose = () => { setTimeout(() => this._startWs(), 3000); };
      this._ws.onerror = () => this._ws?.close();
    } catch(e) { console.log('[ws] error', e); }
  }
}
