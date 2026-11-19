import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';

@Component({
  selector: 'app-settings',
  standalone: true,
  imports: [FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Settings</h1></div>
    <div class="card"><h3 class="section-title">Cloudflare API Credentials</h3><p class="section-desc">Enter your Cloudflare API credentials to manage tunnels.</p>
      <div class="setting-row"><span>Cloudflare Account ID</span><input class="input" [(ngModel)]="settings['cf_account_id']" style="width:320px" placeholder="Account ID"></div>
      <div class="setting-row"><span>Cloudflare API Token</span><input class="input" [(ngModel)]="settings['cf_api_token']" style="width:320px" placeholder="API Token" type="password"></div>
    </div>
    <div class="card"><h3 class="section-title">cloudflared Binary Detection</h3><p class="section-desc">Host executable required to run and manage Cloudflare Tunnels.</p>
      <div class="setting-row">
        <span>Detection Status</span>
        @if (api.cloudflared()?.installed) {
          <span style="color:var(--green);display:flex;align-items:center;gap:6px;font-weight:600">
            <span class="material-icons" style="font-size:16px">check_circle</span> Detected
          </span>
        } @else {
          <span style="color:var(--red);display:flex;align-items:center;gap:6px;font-weight:600">
            <span class="material-icons" style="font-size:16px">error</span> Not Found
          </span>
        }
      </div>
      @if (api.cloudflared()?.installed) {
        <div class="setting-row"><span>Executable Path</span><span class="mono muted">{{api.cloudflared()?.path}}</span></div>
        @if (api.cloudflared()?.version) {
          <div class="setting-row"><span>Version</span><span class="mono muted">{{api.cloudflared()?.version}}</span></div>
        }
      } @else {
        <div style="margin-top:12px;padding:12px;background:rgba(248,113,113,0.08);border:1px solid rgba(248,113,113,0.2);border-radius:8px;font-size:12px;color:var(--muted)">
          <p style="margin-bottom:6px;font-weight:600;color:var(--text)">How to install <code>cloudflared</code>:</p>
          <ul style="padding-left:18px;line-height:1.7">
            <li>macOS (Homebrew): <code>brew install cloudflared</code></li>
            <li>Linux (Debian/Ubuntu): <code>curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && sudo apt-get update && sudo apt-get install cloudflared</code></li>
            <li>Linux (RPM): <code>sudo dnf install cloudflared</code></li>
          </ul>
        </div>
      }
      <div style="margin-top:12px;display:flex;gap:8px">
        <button class="btn btn-ghost btn-sm" (click)="recheckCloudflared()"><span class="material-icons" style="font-size:16px">refresh</span> Re-check Detection</button>
      </div>
    </div>
    <div class="card"><h3 class="section-title">Auto-bind Port Range</h3><p class="section-desc">Only show detection toast for new services within this range.</p>
      <div class="bind-row"><input class="input" [(ngModel)]="settings['auto_bind_min_port']" placeholder="Min port" style="width:120px"><span>–</span><input class="input" [(ngModel)]="settings['auto_bind_max_port']" placeholder="Max port" style="width:120px"></div>
    </div>
    <div class="card"><h3 class="section-title">App Behavior</h3>
      <div class="setting-row"><span>Minimize to tray on close</span><label class="switch"><input type="checkbox" [ngModel]="settings['close_to_tray']==='true'" (change)="settings['close_to_tray']=$any($event.target).checked?'true':'false'"><span></span></label></div>
      <div class="setting-row"><span>Launch on system startup</span><label class="switch"><input type="checkbox" [ngModel]="settings['auto_start']==='true'" (change)="settings['auto_start']=$any($event.target).checked?'true':'false'"><span></span></label></div>
    </div>
    <div class="card"><h3 class="section-title">Daemon Boot Settings</h3><p class="section-desc">Configure how the background daemon handles tunnel starts on system boot.</p>
      <div class="bind-row"><input class="input" [(ngModel)]="settings['boot_delay']" placeholder="Boot delay (seconds)" style="width:180px"><input class="input" [(ngModel)]="settings['max_retries']" placeholder="Max start retries" style="width:180px"></div>
    </div>
    <div class="card"><h3 class="section-title">HTTP API Server</h3><p class="section-desc">Expose app features over HTTP.</p>
      <div class="setting-row"><span>Enable HTTP API</span><label class="switch"><input type="checkbox" [ngModel]="settings['api_enabled']==='true'" (change)="settings['api_enabled']=$any($event.target).checked?'true':'false'"><span></span></label></div>
      <div class="setting-row"><span>API Key</span><input class="input mono muted" [ngModel]="settings['api_key']" style="width:320px;font-size:11px" readonly></div>
    </div>
    <button class="btn btn-primary" (click)="saveSettings()" style="width:100%">Save &amp; Verify</button>
  `,
})
export class SettingsComponent implements OnInit {
  public api = inject(ApiService);
  private toast = inject(ToastService);
  loading = signal(false);
  settings: any = {};

  ngOnInit() { this.loadSettings(); }

  async loadSettings() {
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/settings');
      this.settings = r.settings||{};
      await this.api.checkCloudflared();
    } catch {} finally {
      this.loading.set(false);
    }
  }

  async recheckCloudflared() {
    this.toast.show('Checking cloudflared...');
    const res = await this.api.checkCloudflared(true);
    if (res.installed) {
      this.toast.show('cloudflared detected: ' + (res.path || 'installed'));
    } else {
      this.toast.show('cloudflared is not installed!', true);
    }
  }

  async saveSettings() { this.loading.set(true); try { await this.api.call('/api/settings','PATCH',this.settings); this.toast.show('Saved'); } catch { this.toast.show('Error',true); } finally { this.loading.set(false); } }
}
