# Blog Management Online v4.0

## Komponen
- `Blog Management v4 Online.html` — frontend static.
- `supabase_schema_v4.sql` — schema PostgreSQL, RLS, quota transaction, dan Realtime.

## Setup Supabase
1. Buat project baru di Supabase.
2. Buka **SQL Editor** dan jalankan `supabase_schema_v4.sql`.
3. Pastikan Email Authentication aktif pada **Authentication**.
4. Ambil **Project URL** dan **Publishable Key** dari Supabase Dashboard. Jangan gunakan `service_role` key di HTML.
5. Buka file HTML dan ubah `SUPABASE_CONFIG` di bagian awal script:
   - `url` = Project URL
   - `publishableKey` = Publishable Key
6. Upload file HTML ke hosting sebagai `index.html` (HTTPS disarankan).
7. Pada Supabase Authentication URL Configuration, tambahkan URL website Anda sebagai Site URL / Redirect URL. Ini diperlukan untuk email confirmation dan password recovery.

## Login multi-user
Setiap user login dengan akun Supabase Auth sendiri. RLS membatasi `blogs`, `gmail_accounts`, `creation_logs`, dan `user_settings` berdasarkan `auth.uid()`.

## Multi-device
Login dengan akun yang sama di perangkat berbeda akan membaca data yang sama dari PostgreSQL. Realtime akan menyegarkan perubahan dari perangkat lain; refresh/focus juga melakukan sync ulang.

## Security
Password Gmail TIDAK disimpan ke database/cloud dan tidak ikut backup. Jika password dimasukkan pada form akun Gmail, credential tersebut hanya berada di memory browser selama sesi halaman. Untuk penyimpanan permanen gunakan password manager.

## Migrasi dari v3.1
Ekspor backup JSON dari v3.1 lalu gunakan **Import Blog** pada versi online. Import online melakukan merge dan tidak mengunggah password Gmail ke database. Status `creating/claimed` dari backup lama diubah menjadi `available` agar quota server tidak dapat dipalsukan; pembuatan baru harus melewati fungsi database `start_blog_creation()`.

## Catatan quota
Quota 100 blog total, 10/hari, 3/jam, dan cooldown 5 menit ditegakkan di PostgreSQL melalui RPC `start_blog_creation()`. Row lock pada akun membuat dua perangkat tidak dapat melewati quota secara bersamaan untuk akun yang sama.
