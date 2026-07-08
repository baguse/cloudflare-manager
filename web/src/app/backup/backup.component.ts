import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';
import { ConfirmService } from '../confirm.service';

interface Backup { timestamp: string; path: string; checksum?: string; }

@Component({
  selector: 'app-backup',
  standalone: true,
  imports: [FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Backup &amp; Restore</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="loadBackups()"><span class="material-icons" style="font-size:16px">refresh</span></button></div></div>

    <!-- Create backup -->
    <div class="card">
      <h3 class="section-title">Create Backup</h3>
      <p class="section-desc">Select data to include and optionally password-protect the backup.</p>
      <div class="tag-row" style="margin-bottom:12px">
        @for (s of sections; track s.key) {
          <span class="tag-chip preset" [class.selected]="s.selected" [style.background]="s.selected?'var(--accent)':'transparent'" [style.color]="s.selected?'#fff':'var(--muted)'" [style.border-color]="s.selected?'var(--accent)':'var(--border)'" (click)="s.selected=!s.selected">{{s.label}}</span>
        }
      </div>
      <div class="setting-row"><span>Password protect (optional)</span><label class="switch"><input type="checkbox" [(ngModel)]="usePassword"><span></span></label></div>
      @if (usePassword) {
        <div style="display:flex;gap:4px;margin-top:8px">
          <input class="input" [type]="showPwd?'text':'password'" [(ngModel)]="password" placeholder="Enter password" style="flex:1">
          <button class="btn btn-ghost btn-sm" (click)="showPwd=!showPwd"><span class="material-icons" style="font-size:16px">{{showPwd?'visibility_off':'visibility'}}</span></button>
        </div>
        <div class="setting-row" style="margin-top:8px"><span>Include tunnel credentials (encrypted)</span><label class="switch"><input type="checkbox" [(ngModel)]="includeSecrets"><span></span></label></div>
      }
      <button class="btn btn-primary" style="margin-top:12px" (click)="createBackup()">Create Backup</button>
    </div>

    <!-- Restore by upload -->
    <div class="card">
      <h3 class="section-title">Restore from File</h3>
      <p class="section-desc">Upload a backup .json file to restore configuration.</p>
      <input type="file" accept=".json" (change)="onFileSelect($event)" style="display:none" #fileInput>
      <button class="btn btn-primary btn-sm" (click)="fileInput.click()">Choose File</button>
      @if (selectedFile) { <span class="muted text-xs" style="margin-left:8px">{{selectedFile}}</span> }
    </div>

    <!-- Export -->
    <div class="card">
      <h3 class="section-title">Export Tunnels &amp; DNS</h3>
      <p class="section-desc">Download tunnel and DNS data as JSON or Markdown.</p>
      <div class="bind-row"><button class="btn btn-primary btn-sm" (click)="doExport('json')">Export JSON</button><button class="btn btn-ghost btn-sm" (click)="doExport('md')">Export Markdown</button></div>
    </div>

    <!-- Auto-backups -->
    <div class="card">
      <h3 class="section-title">Auto-Backups</h3>
      <p class="section-desc">Auto-backups store all configs in ~/.cloudflared/backups/. Max 10.</p>
      @if (backups().length === 0) { <div class="empty">No backups yet</div> }
      @for (b of backups(); track b.timestamp) {
        <div class="hook-row" style="border-bottom:1px solid var(--border);padding:8px 0">
          <div class="mono text-sm">{{b.timestamp}}</div>
          <div class="bind-row"><button class="btn btn-ghost btn-xs" (click)="restoreAuto(b)">Restore</button><button class="btn btn-ghost btn-xs danger" (click)="delBackup(b)"><span class="material-icons" style="font-size:14px">delete_outline</span></button></div>
        </div>
      }
    </div>

    <!-- Restore dialog -->
    @if (showRestore) {
      <div class="modal-overlay" (click)="showRestore=false"><div class="modal" (click)="$event.stopPropagation()" style="max-width:480px">
        <div class="modal-head"><span class="material-icons" style="font-size:20px;color:var(--accent)">restore</span><b>Restore Backup</b><button class="btn btn-ghost btn-sm" (click)="showRestore=false"><span class="material-icons" style="font-size:18px">close</span></button></div>
        @if (restorePwd) {
          <label class="field-label">Password</label>
          <div style="display:flex;gap:4px">
            <input class="input" [type]="showPwd?'text':'password'" [(ngModel)]="password" placeholder="Enter backup password" style="flex:1">
            <button class="btn btn-ghost btn-sm" (click)="showPwd=!showPwd"><span class="material-icons" style="font-size:16px">{{showPwd?'visibility_off':'visibility'}}</span></button>
          </div>
          <button class="btn btn-ghost btn-sm" style="margin-top:8px" (click)="loadRestore(true)">Decrypt</button>
        } @else {
          <p class="section-desc">Select sections to restore:</p>
          <div class="tag-row" style="margin-bottom:12px">
            @for (s of restoreSections; track s.key) {
              <span class="tag-chip preset" [class.selected]="s.selected" [style.background]="s.selected?'var(--accent)':'transparent'" [style.color]="s.selected?'#fff':'var(--muted)'" [style.border-color]="s.selected?'var(--accent)':'var(--border)'" (click)="s.selected=!s.selected">{{s.label}}</span>
            }
          </div>
          <button class="btn btn-primary" style="margin-top:8px" (click)="doRestore()">Restore Selected</button>
        }
      </div></div>
    }
  `,
})
export class BackupComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  private confirmSvc = inject(ConfirmService);
  loading = signal(false);
  backups = signal<Backup[]>([]);
  usePassword = false; password = ''; showPwd = false; includeSecrets = false;
  sections = [
    {key:'app_settings',label:'App Settings',selected:true},
    {key:'webhooks',label:'Webhooks',selected:true},
    {key:'app_tunnels',label:'Tunnels',selected:true},
    {key:'daemon',label:'Daemon Config',selected:true},
    {key:'rate_alerts',label:'Rate Alerts',selected:true},
  ];
  showRestore = false; restoreData: any = null; restorePwd = false;
  restoreSections: any[] = [];
  selectedFile = '';

  ngOnInit() { this.loadBackups(); }

  async loadBackups() { this.loading.set(true); try { const r = await this.api.call('/api/backups'); this.backups.set(r.backups||[]); } catch {} finally { this.loading.set(false); } }

  async createBackup() {
    if (this.usePassword && !this.password) return this.toast.show('Enter a password', true);
    this.loading.set(true);
    try {
      const sel = this.sections.filter(s => s.selected).map((s:any) => s.key);
      const r = await this.api.call('/api/backup', 'POST', {sections: sel, password: this.usePassword?this.password:null, includeSecrets: this.includeSecrets&&this.usePassword});
      if (!r.ok) { this.toast.show('Backup failed', true); return; }
      const stamp = new Date().toISOString().split('T')[0];
      const encSuffix = this.usePassword && this.password ? '-encrypted' : '';
      const name = 'cloudflare-manager-backup' + encSuffix + '-' + stamp + '.json';
      const body = typeof r.data === 'string' ? r.data : JSON.stringify(r.data, null, 2);
      const blob = new Blob([body], {type:'application/json'});
      const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
      a.download = name; a.click();
      this.toast.show('Backup downloaded');
      this.password = ''; this.showPwd = false;
      await this.loadBackups();
    } catch { this.toast.show('Error', true); }
    this.loading.set(false);
  }

  async onFileSelect(event: any) {
    const file = event.target.files?.[0];
    if (!file) return;
    this.selectedFile = file.name;
    this.loading.set(true);
    try {
      const raw = await file.text();
      if (raw.startsWith('CFENCv2')) {
      this.restoreData = raw;
      this.restorePwd = true;
      this.showRestore = true;
        this.loading.set(false);
        return;
      }
      let data: any;
      try { data = JSON.parse(raw); } catch { this.toast.show('Invalid JSON file', true); return; }
      this.restoreData = data;
      this.restorePwd = false;
      this.restoreSections = this.sections.map(s => ({...s, selected: data[s.key]!=null}));
      this.showRestore = true;
    } catch { this.toast.show('Failed to read file', true); }
    this.loading.set(false);
  }

  async restoreAuto(b: Backup) {
    this.loading.set(true);
    try {
      const name = b.path.split('/').pop() || b.path;
      const r = await this.api.call('/api/backup?name='+encodeURIComponent(name));
      this.restoreData = r.data;
      this.restorePwd = false;
      this.restoreSections = this.sections.map(s => ({...s, selected: this.restoreData[s.key]!=null}));
      this.showRestore = true;
    } catch { this.toast.show('Failed to fetch backup', true); }
    this.loading.set(false);
  }

  async loadRestore(retry: boolean) {
    if (!this.password) return;
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/backup/decrypt', 'POST', {data: this.restoreData, password: this.password});
      if (!r.ok) { this.toast.show(r.error || 'Wrong password', true); this.loading.set(false); return; }
      this.restoreData = r.data;
      this.restorePwd = false;
      this.password = ''; this.showPwd = false;
      this.restoreSections = this.sections.map(s => ({...s, selected: this.restoreData[s.key]!=null}));
    } catch { this.toast.show('Decryption failed', true); }
    this.loading.set(false);
  }

  async doRestore() {
    const sel = this.restoreSections.filter(s => s.selected).map(s => s.key);
    if (sel.length === 0) return this.toast.show('Select at least one section', true);
    if (!await this.confirmSvc.confirm('Restore ' + sel.length + ' section(s)? This will overwrite existing config.')) return;
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/restore', 'POST', {data: this.restoreData, sections: sel});
      this.toast.show('Restored ' + r.restored + ' section(s)');
      this.password = ''; this.showPwd = false;
      this.showRestore = false;
    } catch { this.toast.show('Restore failed', true); }
    this.loading.set(false);
  }

  async delBackup(b: Backup) {
    if (!await this.confirmSvc.confirm('Delete this backup?')) return;
    this.loading.set(true);
    try {
      const name = b.path.split('/').pop() || b.path;
      await this.api.call('/api/backup?name='+encodeURIComponent(name), 'DELETE');
      this.toast.show('Deleted');
      await this.loadBackups();
    } catch { this.toast.show('Error', true); }
    this.loading.set(false);
  }

  async doExport(fmt: string) {
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/export?format='+fmt);
      const blob = new Blob([JSON.stringify(r)], {type: fmt==='md'?'text/markdown':'application/json'});
      const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
      a.download = 'cloudflare-manager-export.'+fmt; a.click();
    } catch { this.toast.show('Export failed', true); }
    this.loading.set(false);
  }
}
