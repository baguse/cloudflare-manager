import { Injectable, signal, computed } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ApiService {
  private _url = signal(localStorage.getItem('cf_url') || '');
  private _key = signal(localStorage.getItem('cf_key') || '');

  get configured() { return !!this._url() && !!this._key(); }
  get apiUrl() { return this._url(); }
  get apiKey() { return this._key(); }

  connect(url: string, key: string) {
    this._url.set(url); this._key.set(key);
    localStorage.setItem('cf_url', url); localStorage.setItem('cf_key', key);
  }

  async call(path: string, method = 'GET', data?: any): Promise<any> {
    const url = this._url().replace(/\/$/, '') + path;
    const headers: any = { Authorization: 'Bearer ' + this._key() };
    if (data) headers['Content-Type'] = 'application/json';
    const res = await fetch(url, { method, headers, body: data ? JSON.stringify(data) : undefined });
    if (!res.ok) throw await res.json().catch(() => ({ error: res.statusText }));
    return res.json();
  }
}
