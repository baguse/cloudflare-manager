import { Component, OnInit, signal, inject } from '@angular/core';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';

interface Backup { timestamp: string; path: string; }

@Component({
  selector: 'app-backup',
  standalone: true,
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Backup &amp; Restore</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="loadBackups()"><span class="material-icons" style="font-size:16px">refresh</span></button><button class="btn btn-primary btn-sm" (click)="createBackup()">Create Backup</button></div></div>
    @if (backups().length === 0) { <div class="empty">No backups yet</div> }
    @for (b of backups(); track b.timestamp) { <div class="card mono text-sm">{{b.timestamp}}</div> }
  `,
})
export class BackupComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  loading = signal(false);
  backups = signal<Backup[]>([]);

  ngOnInit() { this.loadBackups(); }

  async loadBackups() { this.loading.set(true); try { const r = await this.api.call('/api/backups'); this.backups.set(r.backups||[]); } catch {} finally { this.loading.set(false); } }
  async createBackup() { try { await this.api.call('/api/backup','POST'); this.toast.show('Created'); this.loadBackups(); } catch { this.toast.show('Error',true); } }
}
