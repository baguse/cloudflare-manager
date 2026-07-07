import { Injectable, signal } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ConfirmService {
  show = signal(false);
  message = signal('');
  private _resolve!: (v: boolean) => void;

  confirm(msg: string): Promise<boolean> {
    this.message.set(msg);
    this.show.set(true);
    return new Promise(resolve => { this._resolve = resolve; });
  }

  ok() { this.show.set(false); this._resolve(true); }
  cancel() { this.show.set(false); this._resolve(false); }
}
