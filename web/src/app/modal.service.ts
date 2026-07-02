import { Injectable, signal } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ModalService {
  kind = signal<'qr'|'logs'|null>(null);
  qrData = signal(''); qrDataUrl = signal('');
  logsModal = signal(false); logLines = signal<string[]>([]);
}
