import { Injectable, signal } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ToastService {
  msg = signal('');
  error = signal(false);
  _t: any;

  show(m: string, err = false) {
    this.msg.set(m); this.error.set(err);
    clearTimeout(this._t);
    this._t = setTimeout(() => this.msg.set(''), 3000);
  }

  dismiss() { clearTimeout(this._t); this.msg.set(''); }
}
