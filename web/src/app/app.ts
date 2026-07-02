import { Component, signal, OnInit, inject } from '@angular/core';
import { RouterModule, RouterOutlet, Router } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { ApiService } from './api.service';
import { ModalService } from './modal.service';
import { ToastService } from './toast.service';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterModule, RouterOutlet, FormsModule],
  styles: [],
  template: `
    <div [class.dark]="theme()==='dark'" class="app-shell">
      @if (!api.configured) {
        <div class="login-card">
          <div class="login-icon"><span class="material-icons" style="font-size:48px">cloud</span></div>
          <h2>Cloudflare Manager</h2>
          <p class="login-sub">Connect to your API server</p>
          <input class="input" [(ngModel)]="url" placeholder="API URL (e.g. http://localhost:9845)">
          <input class="input" [(ngModel)]="key" placeholder="API Key">
          <button class="btn btn-primary full" (click)="connect()">Connect</button>
        </div>
      } @else {
        <aside class="sidebar">
          <div class="brand">CF Manager</div>
          @for (t of tabs; track t.id) {
            <a class="sidebar-item" routerLink="/{{t.id}}" routerLinkActive="active"><span class="material-icons" style="font-size:18px;width:18px">{{t.icon}}</span>{{t.label}}</a>
          }
          <div class="sidebar-item" (click)="toggleWatcher()"><span class="material-icons" style="font-size:18px;width:18px">{{watcherEnabled?'visibility':'visibility_off'}}</span>Watcher: {{watcherEnabled?'ON':'OFF'}}</div>
          <div class="sidebar-item danger" (click)="killDaemons()"><span class="material-icons" style="font-size:18px;width:18px">bug_report</span>Kill Daemons</div>
          <div class="sidebar-item daemon-status">
            <span class="material-icons" style="font-size:18px;width:18px">dns</span>
            <span>Daemon: {{daemonRunning()?'Running':'Stopped'}}</span>
            <button class="btn btn-ghost btn-xs" style="margin-left:auto" (click)="daemonRunning()?stopDaemon():startDaemon()">
              <span class="material-icons" style="font-size:16px">{{daemonRunning()?'stop':'play_arrow'}}</span>
            </button>
          </div>
          <div class="spacer"></div>
          <button class="theme-btn" (click)="toggleTheme()"><span class="material-icons" style="font-size:16px">{{theme()==='dark'?'dark_mode':'light_mode'}}</span></button>
          <div class="sidebar-status"><span [class]="'dot '+connDot()"></span>{{connLabel()}}</div>
        </aside>
        <main class="main">
          @if (daemonLoading()) { <div class="loading-bar"></div> }
          <router-outlet></router-outlet>
        </main>

        @if (modals.kind()==='qr') {
          <div class="modal-overlay" (click)="modals.kind.set(null)"><div class="modal" (click)="$event.stopPropagation()" style="width:360px;text-align:center">
            <div class="modal-head"><span class="material-icons" style="font-size:20px;color:var(--accent)">qr_code_2</span><b>Scan to open</b><button class="btn btn-ghost btn-sm" (click)="modals.kind.set(null)"><span class="material-icons" style="font-size:18px">close</span></button></div>
            <div style="background:#fff;border-radius:12px;padding:16px;display:inline-block;margin:8px 0">
              @if (modals.qrDataUrl()) { <img [src]="modals.qrDataUrl()" style="width:240px;height:240px" alt="QR"> }
            </div>
            <div class="mono muted" style="word-break:break-all;margin:8px 0;max-width:100%">{{modals.qrData()}}</div>
            <div class="bind-row" style="justify-content:center">
              <button class="btn btn-ghost btn-sm" (click)="copyQrUrl()"><span class="material-icons" style="font-size:16px">content_copy</span>Copy URL</button>
              <button class="btn btn-primary btn-sm" (click)="openUrl(modals.qrData())"><span class="material-icons" style="font-size:16px">open_in_new</span>Open</button>
            </div>
          </div></div>
        }

        @if (toast.msg()) {
          <div class="toast" [class.toast-err]="toast.error()" (click)="dismissToast()">{{toast.msg()}}</div>
        }
      }
    </div>
  `,
})
export class AppComponent implements OnInit {
  api: ApiService;
  modals = inject(ModalService);
  toast = inject(ToastService);
  url = localStorage.getItem('cf_url') || '';
  key = localStorage.getItem('cf_key') || '';
  theme = signal(localStorage.getItem('cf_theme') || 'dark');
  tabs = [
    { id: 'dashboard', icon: 'dashboard', label: 'Dashboard' },
    { id: 'dns', icon: 'dns', label: 'DNS Editor' },
    { id: 'webhooks', icon: 'webhook', label: 'Webhooks' },
    { id: 'alerts', icon: 'speed', label: 'Rate Alerts' },
    { id: 'backup', icon: 'backup', label: 'Backup & Restore' },
    { id: 'settings', icon: 'settings', label: 'Settings' },
  ];
  connected = signal(false);
  connDot = () => this.connected()?'dot-green':'dot-red';
  connLabel = () => this.connected()?'Connected':'Disconnected';
  watcherEnabled = true;
  daemonRunning = signal(false);
  daemonLoading = signal(false);

  constructor(api: ApiService, private router: Router) { this.api = api; }
  ngOnInit() { document.documentElement.className = 'dark'; if (this.api.configured) { this.connected.set(true); this.checkStatus(); } }

  connect() { this.api.connect(this.url, this.key); this.connected.set(true); this.checkStatus(); this.router.navigateByUrl('/'); }

  toggleTheme() { this.theme.set(this.theme() === 'dark' ? 'light' : 'dark'); localStorage.setItem('cf_theme', this.theme()); document.documentElement.className = this.theme(); }

  async checkStatus() { try { const s = await this.api.call('/api/status','GET'); this.daemonRunning.set(s.running||s.ok||false); } catch {} }

  async startDaemon() { this.daemonLoading.set(true); try { await this.api.call('/api/daemon/start','POST'); this.toast.show('Daemon starting...'); this.daemonRunning.set(true); } catch { this.toast.show('Error',true); } finally { this.daemonLoading.set(false); } }
  async stopDaemon() { if(!confirm('Stop daemon?')) return; this.daemonLoading.set(true); try { await this.api.call('/api/daemon/stop','POST'); this.toast.show('Daemon stopped'); this.daemonRunning.set(false); } catch { this.toast.show('Error',true); } finally { this.daemonLoading.set(false); } }

  toggleWatcher() { this.watcherEnabled = !this.watcherEnabled; this.toast.show('Watcher '+(this.watcherEnabled?'enabled':'disabled')); }
  async killDaemons() { if(!confirm('Kill all cloudflared processes?')) return; this.daemonLoading.set(true); try { await this.api.call('/api/daemon/stop','POST'); this.toast.show('Daemon killed'); } catch { this.toast.show('Error',true); } finally { this.daemonLoading.set(false); } }

  copyQrUrl() { navigator.clipboard.writeText(this.modals.qrData()); this.toast.show('URL copied!'); }
  openUrl(url:string) { window.open(url,'_blank'); }
  dismissToast() { this.toast.dismiss(); }
}
