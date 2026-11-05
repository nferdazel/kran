/* KRAN prototype behaviour. Plain ES2020, no modules, so file:// works everywhere. */
(function () {
  "use strict";

  /* ------------------------------------------------------------------ */
  /* Dictionary: Indonesian is the source, English is a full mode.       */
  /* ------------------------------------------------------------------ */

  var DICT = {
    id: {
      "common.skip": "Lewati ke konten utama",
      "common.appName": "KRAN",
      "common.appSub": "Inti koperasi",
      "common.prototype": "Prototipe, data sintetis",
      "common.syntheticNote":
        "Semua nama, nomor, dan nominal di halaman ini adalah placeholder. Tidak ada data anggota nyata.",
      "common.theme": "Tema",
      "common.themeLight": "Terang",
      "common.themeDark": "Gelap",
      "common.themeLightOn": "Tema terang aktif.",
      "common.themeDarkOn": "Tema gelap aktif.",
      "common.language": "Bahasa",
      "common.langId": "Indonesia",
      "common.langEn": "English",
      "common.localeChanged": "Bahasa: Indonesia.",
      "common.prefNote": "Preferensi tersimpan di peramban ini.",
      "common.settings": "Pengaturan tampilan",
      "common.navMain": "Navigasi utama",
      "common.navWork": "Pekerjaan",
      "common.navPrototype": "Prototipe",
      "common.home": "Indeks",
      "common.kas": "Kas",
      "common.components": "Komponen",
      "common.notBuilt": "Belum dibangun",
      "common.available": "Tersedia",
      "common.open": "Buka",
      "common.close": "Tutup",
      "common.cancel": "Batal",
      "common.retry": "Coba lagi",
      "common.copyRef": "Salin rujukan",
      "common.copied": "Rujukan disalin.",
      "common.copyFailed": "Rujukan tidak bisa disalin otomatis. Pilih teks lalu salin.",
      "common.search": "Cari",
      "common.clearFilters": "Hapus filter",
      "common.loading": "Memuat…",
      "common.prev": "Sebelumnya",
      "common.next": "Berikutnya",
      "common.pageOf": "Halaman {page} dari {total}",
      "common.rangeOf": "{from}-{to} dari {total}",
      "common.rows": "{count} baris",
      "common.demoState": "Contoh state",
      "common.sorted": "Diurutkan menurut {column}, {direction}.",
      "common.asc": "menaik",
      "common.desc": "menurun",
      "common.pageAnnounce": "Halaman {page}, {range}.",
      "common.status": "Status",
      "common.type": "Jenis",
      "common.member": "Anggota",
      "common.amount": "Nominal",
      "common.reference": "Rujukan",
      "common.narration": "Keterangan",
      "common.time": "Jam",
      "common.receipt": "Slip",
      "common.all": "Semua",
      "common.total": "Total",
      "common.required": "Wajib",
      "common.optional": "Opsional",
      "common.idr": "IDR",
      "common.print": "Cetak",
      "common.filter": "Filter",
      "common.actions": "Aksi",
      "common.closeDialog": "Tutup dialog",
      "common.session": "Sesi",
      "common.reload": "Muat ulang",
      "common.none": "Tidak ada",
      "ph.member": "[NAMA ANGGOTA]",
      "ph.memberNo": "[NOMOR ANGGOTA]",
      "ph.accountNo": "[NOMOR REKENING]",
      "ph.branch": "[NAMA CABANG]",
      "ph.cashier": "[NAMA KASIR]",
      "ph.reference": "[RUJUKAN]",
      "status.active": "Aktif",
      "status.dormant": "Dormant",
      "status.closed": "Ditutup",
      "status.posted": "Tersimpan",
      "status.pending": "Menunggu",
      "status.failed": "Gagal",
      "status.approved": "Disetujui",
      "status.rejected": "Ditolak",
      "status.arrears": "Tunggakan",
      "type.deposit": "Setor (masuk)",
      "type.withdrawal": "Tarik (keluar)",
      "index.docTitle": "Prototipe KRAN",
      "index.title": "Prototipe KRAN",
      "index.intro":
        "Fondasi HTML, CSS, dan JavaScript untuk stasiun kas dan pustaka komponen. Tanpa jaringan, tanpa build, tanpa framework.",
      "index.noticeTitle": "Batasan prototipe",
      "index.noticeBody":
        "Prototipe ini menilai struktur, kepadatan, state, dan kontrak aksesibilitas. Angka dan identitas adalah placeholder bertanda. Belum ada API, penyimpanan, atau otentikasi.",
      "index.scopeTitle": "Yang sudah berjalan",
      "index.scope1": "Tema terang dan gelap, tersimpan tanpa kilatan saat dimuat.",
      "index.scope2": "Bahasa Indonesia dan English, tanpa kehilangan isian form.",
      "index.scope3": "Dialog dengan Escape, fokus kembali, dan urutan tab yang wajar.",
      "index.scope4": "Tabel semantik dengan urutan, filter, paginasi, dan total.",
      "index.screensTitle": "Layar",
      "index.tableCaption": "Layar prototipe dan status pembangunannya",
      "index.colScreen": "Layar",
      "index.colStatus": "Status",
      "index.screen.kas": "Kas",
      "index.screen.transfer": "Transfer",
      "index.screen.members": "Anggota",
      "index.screen.memberDetail": "Detail anggota",
      "index.screen.loans": "Pinjaman",
      "index.screen.close": "Tutup kas",
      "index.screen.reports": "Laporan",
      "index.screen.audit": "Audit",
      "index.screen.login": "Masuk",
      "index.screen.balanceSheet": "Neraca",
      "index.screen.components": "Komponen",
      "index.screenNote":
        "Layar yang belum dibangun tetap dicantumkan agar ruang lingkup terlihat, tetapi tidak bisa diklik.",
      "index.howTitle": "Cara memakai",
      "index.how1":
        "Mulai dari Kas untuk melihat stasiun kerja, lalu Komponen untuk setiap state.",
      "index.how2":
        "Tab melewati konten lebih dulu. Pengaturan tema dan bahasa ada setelah konten.",
      "index.how3": "Tema dan bahasa bertahan setelah halaman dimuat ulang.",
      "index.how4":
        "Slip di layar Kas bisa dicetak; navigasi dan form disembunyikan saat cetak.",
      "index.footer": "Berkas ini dibuka langsung dari sistem berkas. Tidak ada permintaan jaringan.",
      "comp.title": "Galeri komponen",
      "comp.docTitle": "Komponen · Prototipe KRAN",
      "comp.sections": "Bagian halaman",
      "comp.intro":
        "Setiap komponen ditampilkan dengan state yang harus ada sebelum dipakai di layar.",
      "comp.sec.button": "Tombol",
      "comp.sec.input": "Input",
      "comp.sec.select": "Select",
      "comp.sec.moneyInput": "MoneyInput",
      "comp.sec.money": "Tampilan uang",
      "comp.sec.status": "StatusBadge",
      "comp.sec.alert": "Alert",
      "comp.sec.empty": "EmptyState",
      "comp.sec.error": "ErrorState",
      "comp.sec.loading": "LoadingState",
      "comp.sec.table": "DataTable",
      "comp.sec.filter": "FilterBar",
      "comp.sec.pagination": "Pagination",
      "comp.sec.review": "ReviewPanel",
      "comp.sec.dialog": "Dialog",
      "comp.sec.session": "SessionLock",
      "comp.sec.pageHeader": "PageHeader",
      "comp.sec.toolbar": "Toolbar",
      "comp.sec.shell": "AppShell nav",
      "comp.contract.button":
        "Native button, nama dari teks terlihat, aria-busy saat memproses, tidak pernah aria-disabled sendirian.",
      "comp.contract.input":
        "Label permanen lewat for/id; aria-describedby berisi hint lalu error; aria-invalid hanya saat salah.",
      "comp.contract.select": "Select native dengan label; tanpa role combobox buatan.",
      "comp.contract.moneyInput":
        "inputmode decimal, label membawa mata uang sekali, error menyebut aturan dan perbaikan, preview bukan live region.",
      "comp.contract.money":
        "Digit tabular, rata kanan, dua desimal, mata uang di header kolom, bukan di setiap sel.",
      "comp.contract.status":
        "Teks adalah maknanya; bentuk dan warna hanya menguatkan. Tidak ada role status.",
      "comp.contract.alert":
        "role alert hanya untuk kegagalan, role status untuk pesan lain; judul adalah paragraf.",
      "comp.contract.empty":
        "Konten statis tanpa role; kind mengubah kalimat, bukan tata letak.",
      "comp.contract.error":
        "role alert setelah tindakan, role status saat muat; rujukan bisa disalin; retry satu-satunya kontrol.",
      "comp.contract.loading":
        "role status dan aria-busy pada wadah; tinggi tetap agar tidak menggeser layout.",
      "comp.contract.table":
        "Region berlabel dengan satu tab stop, caption, th scope, aria-sort pada satu kolom, total di tfoot.",
      "comp.contract.filter":
        "role search berlabel; jumlah hasil diumumkan sopan setelah 400 ms; Enter menerapkan.",
      "comp.contract.pagination":
        "Nav berlabel, tombol teks, aria-current pada halaman aktif, rentang terbaca.",
      "comp.contract.review":
        "Section berlabel; fakta dl; nominal sebagai nilai berlabel; aria-busy saat mengirim; error tetap di panel.",
      "comp.contract.dialog":
        "Dialog native dengan showModal; Escape menutup kecuali sibuk; fokus kembali ke pemicu; Batal fokus awal untuk aksi merusak.",
      "comp.contract.session":
        "Dua pengumuman saja: peringatan 60 detik dan kedaluwarsa; Escape tidak menutup; isian bertahan.",
      "comp.contract.pageHeader": "Satu h1, intro maksimal 60 karakter per baris, satu aksi.",
      "comp.contract.toolbar":
        "Tinggi maksimal 48 px, kontrol asli, bukan deretan ikon tanpa label.",
      "comp.contract.shell":
        "Skip link ke main, landmark header/nav/main, satu h1, pengaturan setelah konten.",
      "comp.state.default": "Default",
      "comp.state.focus": "Fokus",
      "comp.state.error": "Galat",
      "comp.state.disabled": "Nonaktif",
      "comp.state.readonly": "Hanya baca",
      "comp.state.helper": "Helper",
      "comp.state.valid": "Valid",
      "comp.state.empty": "Kosong",
      "comp.state.loading": "Memuat",
      "comp.state.success": "Sukses",
      "comp.state.warning": "Peringatan",
      "comp.state.info": "Info",
      "comp.state.firstRun": "Belum ada data",
      "comp.state.filtered": "Hasil filter kosong",
      "comp.state.filled": "Terisi",
      "comp.button.primary": "Aksi primer",
      "comp.button.secondary": "Aksi sekunder",
      "comp.button.ghost": "Aksi senyap",
      "comp.button.danger": "Tutup kas",
      "comp.button.disabled": "Nonaktif",
      "comp.button.loading": "Menyimpan",
      "comp.button.demoPrimary":
        "Aksi primer dijalankan. Di layar Kas, ini tombol Simpan setoran.",
      "comp.button.demoSecondary": "Aksi sekunder dijalankan. Tidak ada perubahan data.",
      "comp.button.demoGhost": "Aksi senyap dijalankan. Fokus tetap di sini.",
      "comp.button.saved": "Contoh pemrosesan selesai.",
      "comp.input.accountLabel": "Nomor rekening",
      "comp.input.accountHint": "10 digit, ada di buku tabungan.",
      "comp.input.accountValue": "1000000001",
      "comp.input.error": "Nomor rekening wajib 10 digit. Periksa jumlah digit.",
      "comp.input.noteLabel": "Keterangan",
      "comp.input.noteHint": "Tercetak di slip.",
      "comp.input.disabledLabel": "Cabang",
      "comp.input.readonlyLabel": "Kasir",
      "comp.input.helperLabel": "Rujukan",
      "comp.select.label": "Jenis simpanan",
      "comp.select.optionVoluntary": "Simpanan sukarela",
      "comp.select.optionMandatory": "Simpanan wajib",
      "comp.select.optionPrincipal": "Simpanan pokok",
      "comp.select.error": "Pilih jenis simpanan untuk rekening ini.",
      "comp.money.cellLabel": "Sel tabel",
      "comp.money.inlineLabel": "Dalam kalimat",
      "comp.money.summaryLabel": "Ringkasan",
      "comp.money.header": "Nominal (IDR)",
      "comp.money.inlineText": "Saldo setelah transaksi",
      "comp.money.summaryText": "Total setoran sesi (IDR)",
      "comp.status.note": "Tujuh status nyata dari produk. Warna tidak pernah satu-satunya pembeda.",
      "comp.alert.infoTitle": "Periode berjalan",
      "comp.alert.infoBody": "Transaksi tanggal ini masuk ke periode November 2026.",
      "comp.alert.successTitle": "Tersimpan",
      "comp.alert.successBody": "Rujukan TRX-000128 tercatat di sesi ini.",
      "comp.alert.warningTitle": "Kas belum seimbang",
      "comp.alert.warningBody":
        "Ada selisih antara kas fisik dan kas seharusnya. Hitung ulang sebelum menutup sesi.",
      "comp.alert.errorTitle": "Transaksi gagal",
      "comp.alert.errorBody":
        "Saldo tidak cukup untuk penarikan ini. Transaksi tidak disimpan. Periksa saldo, lalu ubah nominal.",
      "comp.empty.firstTitle": "Belum ada transaksi",
      "comp.empty.firstBody": "Transaksi pertama sesi ini akan muncul di sini.",
      "comp.empty.filteredTitle": "Tidak ada yang cocok",
      "comp.empty.filteredBody":
        "Tidak ada transaksi untuk filter ini. Hapus filter untuk melihat semua baris.",
      "comp.error.title": "Daftar transaksi gagal dimuat",
      "comp.error.body": "Coba lagi. Kalau tetap gagal, kirim rujukan ke admin.",
      "comp.error.retry": "Coba lagi",
      "comp.error.success": "Daftar transaksi dimuat ulang.",
      "comp.loading.label": "Memuat transaksi sesi…",
      "comp.table.caption": "Transaksi contoh, 57 baris sintetis",
      "comp.table.searchLabel": "Cari anggota atau rujukan",
      "comp.table.statusAll": "Semua status",
      "comp.table.colTime": "Jam",
      "comp.table.colMember": "Anggota",
      "comp.table.colType": "Jenis",
      "comp.table.colAmount": "Nominal (IDR)",
      "comp.table.colStatus": "Status",
      "comp.table.colRef": "Rujukan",
      "comp.table.total": "Total baris terlihat",
      "comp.table.density": "Kepadatan tabel",
      "comp.table.default": "Default",
      "comp.table.dense": "Padat",
      "comp.filter.searchLabel": "Cari anggota",
      "comp.filter.statusLabel": "Status anggota",
      "comp.filter.caption": "Anggota contoh",
      "comp.pagination.sample": "Contoh paginasi",
      "comp.review.title": "Tinjau setoran",
      "comp.review.member": "Anggota",
      "comp.review.account": "Rekening",
      "comp.review.kind": "Jenis simpanan",
      "comp.review.kindValue": "Simpanan sukarela",
      "comp.review.before": "Saldo sebelum",
      "comp.review.amount": "Nominal (IDR)",
      "comp.review.after": "Saldo sesudah",
      "comp.review.submit": "Simpan setoran",
      "comp.review.success": "Tersimpan. Rujukan TRX-000128.",
      "comp.review.emptyTitle": "Belum ada nominal",
      "comp.review.emptyBody": "Isi nominal di form untuk melihat ringkasan.",
      "comp.review.errorTitle": "Penyimpanan gagal",
      "comp.review.errorBody":
        "Status transaksi belum pasti. Jangan ulangi dengan nominal berbeda. Simpan rujukan, lalu periksa mutasi.",
      "comp.dialog.open": "Buka dialog",
      "comp.dialog.title": "Tutup kas?",
      "comp.dialog.body":
        "Kas sesi ini akan ditutup; transaksi baru tidak bisa diposting.",
      "comp.dialog.note": "Aksi ini tidak bisa dibatalkan.",
      "comp.dialog.confirm": "Tutup kas",
      "comp.dialog.done": "Kas ditutup.",
      "comp.session.open": "Tampilkan kunci sesi",
      "comp.pageHeader.title": "Anggota",
      "comp.pageHeader.intro": "Cari anggota, buka berkas, dan periksa rekening.",
      "comp.pageHeader.action": "Tambah anggota",
      "comp.pageHeader.actionMsg":
        "Formulir tambah anggota belum dibangun di prototipe ini.",
      "comp.pageHeader.actionNote": "Contoh tombol: formulir tambah anggota belum dibangun.",
      "comp.toolbar.reload": "Muat ulang tabel",
      "comp.toolbar.search": "Cari transaksi",
      "comp.toolbar.mode": "Jenis transaksi",
      "comp.toolbar.deposit": "Setor",
      "comp.toolbar.withdrawal": "Tarik",
      "comp.toolbar.reloaded": "Tabel dimuat ulang.",
      "comp.shell.label": "Contoh navigasi",
      "kas.docTitle": "Kas · Prototipe KRAN",
      "kas.title": "Kas",
      "kas.intro":
        "Satu stasiun untuk setoran dan penarikan tunai. Periksa identitas dan nominal sebelum menyimpan.",
      "kas.businessDate": "Tanggal usaha",
      "kas.branch": "Cabang",
      "kas.branchValue": "[NAMA CABANG] · 001",
      "kas.cashier": "Kasir",
      "kas.cashierValue": "[NAMA KASIR]",
      "kas.sessionOpen": "Sesi terbuka",
      "kas.sessionClosed": "Sesi ditutup",
      "kas.closeCash": "Tutup kas",
      "kas.modeGroup": "Jenis transaksi",
      "kas.deposit": "Setor (masuk)",
      "kas.withdrawal": "Tarik (keluar)",
      "kas.account": "Nomor rekening",
      "kas.accountHint": "Ketik 10 digit, lalu Enter. Nomor ada di buku tabungan.",
      "kas.load": "Muat",
      "kas.holder": "Pemilik",
      "kas.memberNo": "Nomor anggota",
      "kas.accountNo": "Rekening",
      "kas.kind": "Jenis simpanan",
      "kas.kindValue": "Simpanan sukarela",
      "kas.status": "Status",
      "kas.balance": "Saldo",
      "kas.loadedAt": "dimuat 08:14",
      "kas.identityTitle": "Rekening",
      "kas.reference": "Rujukan",
      "kas.narration": "Keterangan",
      "kas.narrationHint": "Tercetak di slip.",
      "kas.amount": "Nominal (IDR)",
      "kas.amountHint": "Angka saja. Contoh: 150000 atau 150000,50.",
      "kas.amountErrorZero": "Nominal harus lebih besar dari 0,00.",
      "kas.amountErrorPrecision": "Nominal maksimal dua angka di belakang koma.",
      "kas.amountErrorFunds":
        "Saldo tidak cukup untuk penarikan ini. Periksa saldo, lalu ubah nominal.",
      "kas.reviewTitle": "Periksa sebelum menyimpan",
      "kas.reviewEmptyTitle": "Belum ada nominal",
      "kas.reviewEmptyBody": "Isi nominal di form untuk melihat ringkasan.",
      "kas.reviewErrorTitle": "Penyimpanan gagal",
      "kas.reviewErrorBody":
        "Status transaksi belum pasti. Jangan ulangi dengan nominal berbeda. Simpan rujukan, lalu periksa mutasi.",
      "kas.before": "Saldo sebelum",
      "kas.amountLine": "Nominal (IDR)",
      "kas.after": "Saldo sesudah",
      "kas.submitDeposit": "Simpan setoran",
      "kas.submitWithdrawal": "Simpan penarikan",
      "kas.savedTitle": "Tersimpan",
      "kas.savedBody": "Rujukan {ref}. Saldo sesudah {amount}.",
      "kas.printSlip": "Cetak slip",
      "kas.nextTxn": "Transaksi berikutnya",
      "kas.sessionTitle": "Transaksi sesi ini",
      "kas.tableCaption": "Transaksi tunai pada sesi ini",
      "kas.tableRegion": "Tabel transaksi sesi ini",
      "kas.colTime": "Jam",
      "kas.colType": "Jenis",
      "kas.colMember": "Anggota",
      "kas.colAmount": "Nominal (IDR)",
      "kas.colStatus": "Status",
      "kas.colReceipt": "Slip",
      "kas.totalVisible": "Total baris terlihat (IDR)",
      "kas.searchToggle": "Cari transaksi",
      "kas.searchLabel": "Cari anggota atau rujukan",
      "kas.filterType": "Jenis",
      "kas.allTypes": "Semua jenis",
      "kas.searchEmptyTitle": "Tidak ada transaksi yang cocok",
      "kas.searchEmptyBody": "Hapus filter untuk melihat semua transaksi sesi ini.",
      "kas.demoLock": "Demo kunci sesi",
      "kas.lockTitle": "Sesi berakhir",
      "kas.lockBody":
        "Tidak ada aktivitas selama 14 menit. Isian dan nomor rujukan tetap tersimpan.",
      "kas.lockNote": "Escape tidak menutup layar ini. Pilih Lanjutkan sesi.",
      "kas.lockContinue": "Lanjutkan sesi",
      "kas.lockSignOut": "Keluar",
      "kas.lockExpiredTitle": "Sesi berakhir",
      "kas.lockExpiredBody":
        "Sesi berakhir karena tidak ada aktivitas. Masuk lagi; isian dan nomor rujukan Anda masih tersimpan.",
      "kas.lockContinueAnnounce": "Sesi dilanjutkan. Isian tidak berubah.",
      "kas.lockExpiredAnnounce": "Sesi berakhir. Masuk lagi untuk melanjutkan.",
      "kas.confirmCloseTitle": "Tutup kas?",
      "kas.confirmCloseBody":
        "Kas sesi ini akan ditutup; transaksi baru tidak bisa diposting.",
      "kas.confirmCloseOk": "Tutup kas",
      "kas.closeDone": "Kas sesi ditutup. Transaksi baru tidak bisa diposting.",
      "kas.closedBanner": "Kas sudah ditutup. Layar ini hanya bisa dibaca.",
      "kas.reopen": "Buka kas",
      "kas.reopened": "Kas dibuka kembali.",
      "kas.demoStates": "Contoh state panel",
      "kas.stateFilled": "Terisi",
      "kas.stateEmpty": "Kosong",
      "kas.stateError": "Galat",
      "kas.slipTitle": "Slip transaksi tunai",
      "kas.slipBranch": "Cabang",
      "kas.slipDate": "Tanggal usaha",
      "kas.slipTime": "Waktu",
      "kas.slipMember": "Anggota",
      "kas.slipMemberNo": "Nomor anggota",
      "kas.slipAccount": "Rekening",
      "kas.slipDirection": "Arah",
      "kas.slipAmount": "Nominal (IDR)",
      "kas.slipNote": "Keterangan",
      "kas.slipCashier": "Kasir",
      "kas.slipRef": "Rujukan",
      "kas.slipSession": "Rekap sesi (IDR)",
      "kas.slipCount": "Jumlah transaksi",
      "kas.slipIn": "Total masuk",
      "kas.slipOut": "Total keluar",
      "kas.slipPrint": "Cetak",
      "kas.slipClose": "Tutup",
      "kas.slipReprint": "SALINAN",
      "kas.errorSummary": "Periksa isian yang ditandai.",
      "kas.loadingAccount": "Mencari rekening…",
      "kas.accountLoaded": "Rekening dimuat.",
      "kas.accountNotFound": "Rekening tidak ditemukan. Periksa nomor lalu coba lagi.",
      "kas.sessionLimit": "Kas sudah ditutup."
    },
    en: {
      "common.skip": "Skip to main content",
      "common.appName": "KRAN",
      "common.appSub": "Cooperative core",
      "common.prototype": "Prototype, synthetic data",
      "common.syntheticNote":
        "Every name, number and amount on this page is a placeholder. No real member data.",
      "common.theme": "Theme",
      "common.themeLight": "Light",
      "common.themeDark": "Dark",
      "common.themeLightOn": "Light theme on.",
      "common.themeDarkOn": "Dark theme on.",
      "common.language": "Language",
      "common.langId": "Indonesian",
      "common.langEn": "English",
      "common.localeChanged": "Language: English.",
      "common.prefNote": "Preferences are stored in this browser.",
      "common.settings": "Display settings",
      "common.navMain": "Main navigation",
      "common.navWork": "Work",
      "common.navPrototype": "Prototype",
      "common.home": "Index",
      "common.kas": "Cash",
      "common.components": "Components",
      "common.notBuilt": "Not built",
      "common.available": "Available",
      "common.open": "Open",
      "common.close": "Close",
      "common.cancel": "Cancel",
      "common.retry": "Try again",
      "common.copyRef": "Copy reference",
      "common.copied": "Reference copied.",
      "common.copyFailed": "The reference could not be copied automatically. Select the text and copy it.",
      "common.search": "Search",
      "common.clearFilters": "Clear filters",
      "common.loading": "Loading…",
      "common.prev": "Previous",
      "common.next": "Next",
      "common.pageOf": "Page {page} of {total}",
      "common.rangeOf": "{from}-{to} of {total}",
      "common.rows": "{count} rows",
      "common.demoState": "State demo",
      "common.sorted": "Sorted by {column}, {direction}.",
      "common.asc": "ascending",
      "common.desc": "descending",
      "common.pageAnnounce": "Page {page}, {range}.",
      "common.status": "Status",
      "common.type": "Type",
      "common.member": "Member",
      "common.amount": "Amount",
      "common.reference": "Reference",
      "common.narration": "Note",
      "common.time": "Time",
      "common.receipt": "Receipt",
      "common.all": "All",
      "common.total": "Total",
      "common.required": "Required",
      "common.optional": "Optional",
      "common.idr": "IDR",
      "common.print": "Print",
      "common.filter": "Filter",
      "common.actions": "Actions",
      "common.closeDialog": "Close dialog",
      "common.session": "Session",
      "common.reload": "Reload",
      "common.none": "None",
      "ph.member": "[MEMBER NAME]",
      "ph.memberNo": "[MEMBER NUMBER]",
      "ph.accountNo": "[ACCOUNT NUMBER]",
      "ph.branch": "[BRANCH NAME]",
      "ph.cashier": "[TELLER NAME]",
      "ph.reference": "[REFERENCE]",
      "status.active": "Active",
      "status.dormant": "Dormant",
      "status.closed": "Closed",
      "status.posted": "Saved",
      "status.pending": "Pending",
      "status.failed": "Failed",
      "status.approved": "Approved",
      "status.rejected": "Rejected",
      "status.arrears": "Arrears",
      "type.deposit": "Deposit (in)",
      "type.withdrawal": "Withdrawal (out)",
      "index.docTitle": "KRAN prototype",
      "index.title": "KRAN prototype",
      "index.intro":
        "An HTML, CSS and JavaScript foundation for the cash station and the component library. No network, no build, no framework.",
      "index.noticeTitle": "Prototype scope",
      "index.noticeBody":
        "This prototype evaluates structure, density, states and the accessibility contract. Amounts and identities are labelled placeholders. There is no API, storage or authentication yet.",
      "index.scopeTitle": "What works",
      "index.scope1": "Light and dark theme, stored and applied without a flash.",
      "index.scope2": "Indonesian and English, without losing form state.",
      "index.scope3": "Dialogs with Escape, restored focus and a sane tab order.",
      "index.scope4": "Semantic tables with sort, filter, pagination and totals.",
      "index.screensTitle": "Screens",
      "index.tableCaption": "Prototype screens and their build status",
      "index.colScreen": "Screen",
      "index.colStatus": "Status",
      "index.screen.kas": "Cash",
      "index.screen.transfer": "Transfer",
      "index.screen.members": "Members",
      "index.screen.memberDetail": "Member detail",
      "index.screen.loans": "Loans",
      "index.screen.close": "Close cash",
      "index.screen.reports": "Reports",
      "index.screen.audit": "Audit",
      "index.screen.login": "Sign in",
      "index.screen.balanceSheet": "Balance sheet",
      "index.screen.components": "Components",
      "index.screenNote":
        "Screens that are not built are listed so the scope stays visible, but they are not links.",
      "index.howTitle": "How to use",
      "index.how1": "Start with Cash for the workstation, then Components for every state.",
      "index.how2": "Tab reaches content first. Theme and language settings sit after the content.",
      "index.how3": "Theme and language persist across reloads.",
      "index.how4": "The receipt in Cash prints; navigation and forms are hidden when printing.",
      "index.footer": "This file opens directly from the file system. It makes no network requests.",
      "comp.title": "Component gallery",
      "comp.docTitle": "Components · KRAN prototype",
      "comp.sections": "Page sections",
      "comp.intro":
        "Every component is shown with the states it needs before it is used on a screen.",
      "comp.sec.button": "Button",
      "comp.sec.input": "Input",
      "comp.sec.select": "Select",
      "comp.sec.moneyInput": "MoneyInput",
      "comp.sec.money": "Money display",
      "comp.sec.status": "StatusBadge",
      "comp.sec.alert": "Alert",
      "comp.sec.empty": "EmptyState",
      "comp.sec.error": "ErrorState",
      "comp.sec.loading": "LoadingState",
      "comp.sec.table": "DataTable",
      "comp.sec.filter": "FilterBar",
      "comp.sec.pagination": "Pagination",
      "comp.sec.review": "ReviewPanel",
      "comp.sec.dialog": "Dialog",
      "comp.sec.session": "SessionLock",
      "comp.sec.pageHeader": "PageHeader",
      "comp.sec.toolbar": "Toolbar",
      "comp.sec.shell": "AppShell nav",
      "comp.contract.button":
        "Native button, name from visible text, aria-busy while working, never aria-disabled alone.",
      "comp.contract.input":
        "Permanent label via for/id; aria-describedby carries hint then error; aria-invalid only when wrong.",
      "comp.contract.select": "Native select with a label; no custom combobox role.",
      "comp.contract.moneyInput":
        "inputmode decimal, label carries the currency once, error names the rule and the fix, preview is not a live region.",
      "comp.contract.money":
        "Tabular digits, right aligned, two decimals, currency in the column header, never in each cell.",
      "comp.contract.status":
        "The text is the meaning; shape and colour only reinforce it. No status role.",
      "comp.contract.alert":
        "role alert only for failure, role status for other messages; the title is a paragraph.",
      "comp.contract.empty":
        "Static content with no role; kind changes the sentence, not the layout.",
      "comp.contract.error":
        "role alert after an action, role status on load; reference can be copied; retry is the only control.",
      "comp.contract.loading":
        "role status and aria-busy on the container; fixed height so layout does not shift.",
      "comp.contract.table":
        "Labelled region with one tab stop, caption, th scope, aria-sort on one column, totals in tfoot.",
      "comp.contract.filter":
        "Labelled role search; result count announced politely after 400 ms; Enter applies.",
      "comp.contract.pagination":
        "Labelled nav, text buttons, aria-current on the active page, readable range.",
      "comp.contract.review":
        "Labelled section; facts as dl; amount as a labelled value; aria-busy while posting; error stays in the panel.",
      "comp.contract.dialog":
        "Native dialog with showModal; Escape closes unless busy; focus returns to the trigger; Cancel is initial focus for destructive work.",
      "comp.contract.session":
        "Exactly two announcements: the 60 second warning and expiry; Escape does not close; form state survives.",
      "comp.contract.pageHeader": "One h1, intro capped at 60 characters per line, one action.",
      "comp.contract.toolbar":
        "Maximum height 48 px, real controls, not a row of icons without labels.",
      "comp.contract.shell":
        "Skip link to main, header/nav/main landmarks, one h1, settings after content.",
      "comp.state.default": "Default",
      "comp.state.focus": "Focus",
      "comp.state.error": "Error",
      "comp.state.disabled": "Disabled",
      "comp.state.readonly": "Read only",
      "comp.state.helper": "Helper",
      "comp.state.valid": "Valid",
      "comp.state.empty": "Empty",
      "comp.state.loading": "Loading",
      "comp.state.success": "Success",
      "comp.state.warning": "Warning",
      "comp.state.info": "Info",
      "comp.state.firstRun": "No data yet",
      "comp.state.filtered": "Filtered empty",
      "comp.state.filled": "Filled",
      "comp.button.primary": "Primary action",
      "comp.button.secondary": "Secondary action",
      "comp.button.ghost": "Ghost action",
      "comp.button.danger": "Close cash",
      "comp.button.disabled": "Disabled",
      "comp.button.loading": "Saving",
      "comp.button.demoPrimary":
        "Primary action ran. On the Cash screen this is the Save deposit button.",
      "comp.button.demoSecondary": "Secondary action ran. No data changed.",
      "comp.button.demoGhost": "Ghost action ran. Focus stays here.",
      "comp.button.saved": "Sample processing finished.",
      "comp.input.accountLabel": "Account number",
      "comp.input.accountHint": "10 digits, printed in the passbook.",
      "comp.input.accountValue": "1000000001",
      "comp.input.error": "Account number must be 10 digits. Check the digit count.",
      "comp.input.noteLabel": "Note",
      "comp.input.noteHint": "Printed on the receipt.",
      "comp.input.disabledLabel": "Branch",
      "comp.input.readonlyLabel": "Teller",
      "comp.input.helperLabel": "Reference",
      "comp.select.label": "Savings type",
      "comp.select.optionVoluntary": "Voluntary savings",
      "comp.select.optionMandatory": "Mandatory savings",
      "comp.select.optionPrincipal": "Principal savings",
      "comp.select.error": "Choose a savings type for this account.",
      "comp.money.cellLabel": "Table cell",
      "comp.money.inlineLabel": "Inline",
      "comp.money.summaryLabel": "Summary",
      "comp.money.header": "Amount (IDR)",
      "comp.money.inlineText": "Balance after the transaction",
      "comp.money.summaryText": "Session deposit total (IDR)",
      "comp.status.note": "Seven real product statuses. Colour is never the only differentiator.",
      "comp.alert.infoTitle": "Open period",
      "comp.alert.infoBody": "Transactions dated today post to the November 2026 period.",
      "comp.alert.successTitle": "Saved",
      "comp.alert.successBody": "Reference TRX-000128 is recorded in this session.",
      "comp.alert.warningTitle": "Cash does not balance",
      "comp.alert.warningBody":
        "Physical cash and expected cash differ. Recount before closing the session.",
      "comp.alert.errorTitle": "Transaction failed",
      "comp.alert.errorBody":
        "The balance is too low for this withdrawal. The transaction was not saved. Check the balance and change the amount.",
      "comp.empty.firstTitle": "No transactions yet",
      "comp.empty.firstBody": "The first transaction of this session will appear here.",
      "comp.empty.filteredTitle": "Nothing matches",
      "comp.empty.filteredBody":
        "No transactions match this filter. Clear the filter to see every row.",
      "comp.error.title": "The transaction list failed to load",
      "comp.error.body": "Try again. If it keeps failing, send the reference to the admin.",
      "comp.error.retry": "Try again",
      "comp.error.success": "The transaction list was reloaded.",
      "comp.loading.label": "Loading session transactions…",
      "comp.table.caption": "Sample transactions, 57 synthetic rows",
      "comp.table.searchLabel": "Search member or reference",
      "comp.table.statusAll": "All statuses",
      "comp.table.colTime": "Time",
      "comp.table.colMember": "Member",
      "comp.table.colType": "Type",
      "comp.table.colAmount": "Amount (IDR)",
      "comp.table.colStatus": "Status",
      "comp.table.colRef": "Reference",
      "comp.table.total": "Total visible rows",
      "comp.table.density": "Table density",
      "comp.table.default": "Default",
      "comp.table.dense": "Dense",
      "comp.filter.searchLabel": "Search member",
      "comp.filter.statusLabel": "Member status",
      "comp.filter.caption": "Sample members",
      "comp.pagination.sample": "Pagination sample",
      "comp.review.title": "Review deposit",
      "comp.review.member": "Member",
      "comp.review.account": "Account",
      "comp.review.kind": "Savings type",
      "comp.review.kindValue": "Voluntary savings",
      "comp.review.before": "Balance before",
      "comp.review.amount": "Amount (IDR)",
      "comp.review.after": "Balance after",
      "comp.review.submit": "Save deposit",
      "comp.review.success": "Saved. Reference TRX-000128.",
      "comp.review.emptyTitle": "No amount yet",
      "comp.review.emptyBody": "Enter an amount in the form to see the summary.",
      "comp.review.errorTitle": "Save failed",
      "comp.review.errorBody":
        "The transaction state is unknown. Do not retry with a different amount. Keep the reference and check the statement.",
      "comp.dialog.open": "Open dialog",
      "comp.dialog.title": "Close cash?",
      "comp.dialog.body":
        "This session's cash will be closed; new transactions cannot be posted.",
      "comp.dialog.note": "This action cannot be undone.",
      "comp.dialog.confirm": "Close cash",
      "comp.dialog.done": "Cash closed.",
      "comp.session.open": "Show session lock",
      "comp.pageHeader.title": "Members",
      "comp.pageHeader.intro": "Find a member, open the file and check accounts.",
      "comp.pageHeader.action": "Add member",
      "comp.pageHeader.actionMsg": "The add member form is not built in this prototype.",
      "comp.pageHeader.actionNote": "Sample button: the add member form is not built.",
      "comp.toolbar.reload": "Reload table",
      "comp.toolbar.search": "Search transactions",
      "comp.toolbar.mode": "Transaction type",
      "comp.toolbar.deposit": "Deposit",
      "comp.toolbar.withdrawal": "Withdrawal",
      "comp.toolbar.reloaded": "Table reloaded.",
      "comp.shell.label": "Sample navigation",
      "kas.docTitle": "Cash · KRAN prototype",
      "kas.title": "Cash",
      "kas.intro":
        "One station for cash deposits and withdrawals. Check identity and amount before saving.",
      "kas.businessDate": "Business date",
      "kas.branch": "Branch",
      "kas.branchValue": "[BRANCH NAME] · 001",
      "kas.cashier": "Teller",
      "kas.cashierValue": "[TELLER NAME]",
      "kas.sessionOpen": "Session open",
      "kas.sessionClosed": "Session closed",
      "kas.closeCash": "Close cash",
      "kas.modeGroup": "Transaction type",
      "kas.deposit": "Deposit (in)",
      "kas.withdrawal": "Withdrawal (out)",
      "kas.account": "Account number",
      "kas.accountHint": "Type 10 digits, then Enter. The number is in the passbook.",
      "kas.load": "Load",
      "kas.holder": "Holder",
      "kas.memberNo": "Member number",
      "kas.accountNo": "Account",
      "kas.kind": "Savings type",
      "kas.kindValue": "Voluntary savings",
      "kas.status": "Status",
      "kas.balance": "Balance",
      "kas.loadedAt": "loaded 08:14",
      "kas.identityTitle": "Account",
      "kas.reference": "Reference",
      "kas.narration": "Note",
      "kas.narrationHint": "Printed on the receipt.",
      "kas.amount": "Amount (IDR)",
      "kas.amountHint": "Digits only. Example: 150000 or 150000.50.",
      "kas.amountErrorZero": "Amount must be greater than 0.00.",
      "kas.amountErrorPrecision": "Amount allows at most two decimal places.",
      "kas.amountErrorFunds":
        "The balance is too low for this withdrawal. Check the balance and change the amount.",
      "kas.reviewTitle": "Check before saving",
      "kas.reviewEmptyTitle": "No amount yet",
      "kas.reviewEmptyBody": "Enter an amount in the form to see the summary.",
      "kas.reviewErrorTitle": "Save failed",
      "kas.reviewErrorBody":
        "The transaction state is unknown. Do not retry with a different amount. Keep the reference and check the statement.",
      "kas.before": "Balance before",
      "kas.amountLine": "Amount (IDR)",
      "kas.after": "Balance after",
      "kas.submitDeposit": "Save deposit",
      "kas.submitWithdrawal": "Save withdrawal",
      "kas.savedTitle": "Saved",
      "kas.savedBody": "Reference {ref}. Balance after {amount}.",
      "kas.printSlip": "Print receipt",
      "kas.nextTxn": "Next transaction",
      "kas.sessionTitle": "Transactions in this session",
      "kas.tableCaption": "Cash transactions in this session",
      "kas.tableRegion": "Session transaction table",
      "kas.colTime": "Time",
      "kas.colType": "Type",
      "kas.colMember": "Member",
      "kas.colAmount": "Amount (IDR)",
      "kas.colStatus": "Status",
      "kas.colReceipt": "Receipt",
      "kas.totalVisible": "Total visible rows (IDR)",
      "kas.searchToggle": "Search transactions",
      "kas.searchLabel": "Search member or reference",
      "kas.filterType": "Type",
      "kas.allTypes": "All types",
      "kas.searchEmptyTitle": "No matching transactions",
      "kas.searchEmptyBody": "Clear the filter to see every transaction in this session.",
      "kas.demoLock": "Session lock demo",
      "kas.lockTitle": "Session ending",
      "kas.lockBody":
        "No activity for 14 minutes. Your draft and reference number are kept.",
      "kas.lockNote": "Escape does not close this screen. Choose Continue session.",
      "kas.lockContinue": "Continue session",
      "kas.lockSignOut": "Sign out",
      "kas.lockExpiredTitle": "Session ended",
      "kas.lockExpiredBody":
        "The session ended after inactivity. Sign in again; your draft and reference number are still kept.",
      "kas.lockContinueAnnounce": "Session continued. The draft is unchanged.",
      "kas.lockExpiredAnnounce": "Session ended. Sign in again to continue.",
      "kas.confirmCloseTitle": "Close cash?",
      "kas.confirmCloseBody":
        "This session's cash will be closed; new transactions cannot be posted.",
      "kas.confirmCloseOk": "Close cash",
      "kas.closeDone": "Session cash closed. New transactions cannot be posted.",
      "kas.closedBanner": "Cash is closed. This screen is read only.",
      "kas.reopen": "Open cash",
      "kas.reopened": "Cash is open again.",
      "kas.demoStates": "Panel state demo",
      "kas.stateFilled": "Filled",
      "kas.stateEmpty": "Empty",
      "kas.stateError": "Error",
      "kas.slipTitle": "Cash transaction receipt",
      "kas.slipBranch": "Branch",
      "kas.slipDate": "Business date",
      "kas.slipTime": "Time",
      "kas.slipMember": "Member",
      "kas.slipMemberNo": "Member number",
      "kas.slipAccount": "Account",
      "kas.slipDirection": "Direction",
      "kas.slipAmount": "Amount (IDR)",
      "kas.slipNote": "Note",
      "kas.slipCashier": "Teller",
      "kas.slipRef": "Reference",
      "kas.slipSession": "Session totals (IDR)",
      "kas.slipCount": "Transaction count",
      "kas.slipIn": "Total in",
      "kas.slipOut": "Total out",
      "kas.slipPrint": "Print",
      "kas.slipClose": "Close",
      "kas.slipReprint": "COPY",
      "kas.errorSummary": "Check the marked fields.",
      "kas.loadingAccount": "Looking up the account…",
      "kas.accountLoaded": "Account loaded.",
      "kas.accountNotFound": "Account not found. Check the number and try again.",
      "kas.sessionLimit": "Cash is closed."
    }
  };

  /* Page-scoped dictionaries for screens built after the foundation. The page
   * loads `assets/i18n-*.js` before this file; the hook merges it here so the
   * existing locale toggle keeps working without editing this file. */
  (function mergeExtraDictionary() {
    var extra = window.KRAN_EXTRA_I18N;
    if (!extra || typeof extra !== "object") {
      return;
    }
    ["id", "en"].forEach(function (locale) {
      var source = extra[locale];
      if (!source) {
        return;
      }
      Object.keys(source).forEach(function (key) {
        DICT[locale][key] = source[key];
      });
    });
  })();

  /* ------------------------------------------------------------------ */
  /* State and small helpers                                             */
  /* ------------------------------------------------------------------ */

  var state = {
    locale: document.documentElement.lang.indexOf("en") === 0 ? "en" : "id",
    theme: document.documentElement.getAttribute("data-theme") || "light"
  };

  var localeHooks = [];
  var lastAnnouncement = { message: "", at: 0 };
  var lastDialogTrigger = null;

  function localeTag() {
    return state.locale === "en" ? "en-US" : "id-ID";
  }

  function t(key, vars) {
    var source = DICT[state.locale] || DICT.id;
    var text = Object.prototype.hasOwnProperty.call(source, key) ? source[key] : DICT.id[key];
    if (typeof text !== "string") {
      return key;
    }
    if (vars) {
      Object.keys(vars).forEach(function (name) {
        text = text.split("{" + name + "}").join(String(vars[name]));
      });
    }
    return text;
  }

  function $(selector, root) {
    return (root || document).querySelector(selector);
  }

  function $all(selector, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(selector));
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    if (typeof text === "string") {
      node.textContent = text;
    }
    return node;
  }

  function formatInt(value) {
    return new Intl.NumberFormat(localeTag(), { maximumFractionDigits: 0 }).format(value);
  }

  function formatMoney(raw) {
    var source = String(raw === undefined || raw === null ? "0" : raw).trim();
    var negative = source.charAt(0) === "-";
    var unsigned = negative ? source.slice(1) : source;
    var parts = unsigned.split(/[.,]/);
    var whole = (parts[0] || "0").replace(/\D/g, "") || "0";
    var fraction = ((parts[1] || "").replace(/\D/g, "") + "00").slice(0, 2);
    var grouped = new Intl.NumberFormat(localeTag(), {
      useGrouping: true,
      maximumFractionDigits: 0
    }).format(BigInt(whole));
    return (negative ? "-" : "") + grouped + (state.locale === "en" ? "." : ",") + fraction;
  }

  function toCents(raw) {
    if (raw === null || raw === undefined || raw === "") {
      return null;
    }
    var source = String(raw).trim().replace(",", ".");
    if (!/^-?\d+(\.\d{0,2})?$/.test(source)) {
      return null;
    }
    var negative = source.charAt(0) === "-";
    var unsigned = negative ? source.slice(1) : source;
    var parts = unsigned.split(".");
    var whole = parts[0] || "0";
    var fraction = ((parts[1] || "") + "00").slice(0, 2);
    var cents = BigInt(whole) * 100n + BigInt(fraction);
    return negative ? -cents : cents;
  }

  function fromCents(cents) {
    var negative = cents < 0n;
    var absolute = negative ? -cents : cents;
    return (negative ? "-" : "") + (absolute / 100n).toString() + "." + (absolute % 100n).toString().padStart(2, "0");
  }

  function formatDate(raw) {
    var date = new Date(raw + "T00:00:00+07:00");
    return new Intl.DateTimeFormat(localeTag(), {
      day: "numeric",
      month: "short",
      year: "numeric",
      timeZone: "Asia/Jakarta"
    }).format(date);
  }

  function announce(message) {
    var live = document.getElementById("live");
    if (!live) {
      return;
    }
    var now = Date.now();
    if (message === lastAnnouncement.message && now - lastAnnouncement.at < 10000) {
      return;
    }
    lastAnnouncement = { message: message, at: now };
    live.textContent = "";
    window.requestAnimationFrame(function () {
      live.textContent = message;
    });
  }

  function setTheme(theme, shouldAnnounce) {
    state.theme = theme;
    document.documentElement.setAttribute("data-theme", theme);
    try {
      window.localStorage.setItem("kran.theme", theme);
    } catch (error) {
      /* storage can be blocked; the theme still applies for this load */
    }
    updateToggles();
    if (shouldAnnounce) {
      announce(t(theme === "dark" ? "common.themeDarkOn" : "common.themeLightOn"));
    }
  }

  function applyLocale(locale, shouldAnnounce) {
    state.locale = locale;
    document.documentElement.lang = locale === "en" ? "en-US" : "id-ID";
    var titleKey = document.body.getAttribute("data-title-key");
    if (titleKey) {
      document.title = t(titleKey);
    }
    try {
      window.localStorage.setItem("kran.locale", locale);
    } catch (error) {
      /* storage can be blocked; the locale still applies for this load */
    }

    $all("[data-i18n]").forEach(function (node) {
      node.textContent = t(node.getAttribute("data-i18n"));
    });
    $all("[data-i18n-placeholder]").forEach(function (node) {
      node.setAttribute("placeholder", t(node.getAttribute("data-i18n-placeholder")));
    });
    $all("[data-i18n-aria-label]").forEach(function (node) {
      node.setAttribute("aria-label", t(node.getAttribute("data-i18n-aria-label")));
    });
    $all("[data-i18n-title]").forEach(function (node) {
      node.setAttribute("title", t(node.getAttribute("data-i18n-title")));
    });

    formatMoneyNodes(document);
    formatDateNodes(document);
    updateToggles();
    localeHooks.forEach(function (hook) {
      hook();
    });
    if (shouldAnnounce) {
      announce(t("common.localeChanged"));
    }
  }

  function updateToggles() {
    $all("[data-theme-set]").forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-theme-set") === state.theme));
    });
    $all("[data-locale-set]").forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-locale-set") === state.locale));
    });
  }

  function formatMoneyNodes(root) {
    $all("[data-money]", root).forEach(function (node) {
      var sign = node.getAttribute("data-money-sign");
      node.textContent = (sign ? sign + " " : "") + formatMoney(node.getAttribute("data-money"));
    });
  }

  function formatDateNodes(root) {
    $all("[data-date]", root).forEach(function (node) {
      node.textContent = formatDate(node.getAttribute("data-date"));
    });
  }

  /* ------------------------------------------------------------------ */
  /* Icons                                                               */
  /* ------------------------------------------------------------------ */

  var ICONS = {
    check: '<path d="m5 12 5 5 9-10"/>',
    alert: '<path d="M12 3 22 20H2Z"/><path d="M12 9v5"/><path d="M12 17h.01"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6"/><path d="M12 7h.01"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    minus: '<circle cx="12" cy="12" r="9"/><path d="M8 12h8"/>',
    x: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6"/><path d="m15 9-6 6"/>',
    sort: '<path d="M8 5v14"/><path d="m5 8 3-3 3 3"/><path d="M16 19V5"/><path d="m13 16 3 3 3-3"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    printer: '<path d="M7 9V3h10v6"/><path d="M7 17H5a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-2"/><path d="M7 14h10v7H7Z"/>',
    lock: '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
    left: '<path d="m15 6-6 6 6 6"/>',
    right: '<path d="m9 6 6 6-6 6"/>'
  };

  function icon(name, className) {
    var template = document.createElement("template");
    template.innerHTML =
      '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" class="' +
      (className || "icon") +
      '">' +
      (ICONS[name] || ICONS.info) +
      "</svg>";
    return template.content.firstElementChild;
  }

  function badge(statusKey) {
    var tones = {
      active: ["success", "check"],
      posted: ["success", "check"],
      approved: ["success", "check"],
      dormant: ["warning", "clock"],
      pending: ["info", "clock"],
      arrears: ["danger", "alert"],
      failed: ["danger", "x"],
      rejected: ["danger", "x"],
      closed: ["neutral", "minus"]
    };
    var tone = tones[statusKey] || ["neutral", "minus"];
    var span = el("span", "badge" + (tone[0] === "neutral" ? "" : " badge--" + tone[0]));
    span.appendChild(icon(tone[1], "icon icon--sm"));
    span.appendChild(el("span", "", t("status." + statusKey)));
    return span;
  }

  /* ------------------------------------------------------------------ */
  /* Theme, locale, money inputs, dialogs, copy, session lock            */
  /* ------------------------------------------------------------------ */

  function initSettings() {
    $all("[data-theme-set]").forEach(function (button) {
      button.addEventListener("click", function () {
        setTheme(button.getAttribute("data-theme-set"), true);
      });
    });
    $all("[data-locale-set]").forEach(function (button) {
      button.addEventListener("click", function () {
        applyLocale(button.getAttribute("data-locale-set"), true);
      });
    });
    updateToggles();
  }

  function initBadges() {
    function paint() {
      $all("[data-badge]").forEach(function (node) {
        var fresh = badge(node.getAttribute("data-badge"));
        node.className = fresh.className;
        node.replaceChildren.apply(node, Array.prototype.slice.call(fresh.childNodes));
      });
    }
    localeHooks.push(paint);
    paint();
  }

  function initSegments() {
    $all("[data-segment-group]").forEach(function (group) {
      var buttons = $all("button", group);
      buttons.forEach(function (button) {
        button.addEventListener("click", function () {
          buttons.forEach(function (other) {
            other.setAttribute("aria-pressed", String(other === button));
          });
        });
      });
    });
  }

  function initButtonDemo() {
    var button = document.getElementById("button-loading");
    if (!button) {
      return;
    }
    var spinner = button.querySelector(".btn__spinner");
    button.addEventListener("click", function () {
      if (button.getAttribute("aria-busy") === "true") {
        return;
      }
      button.setAttribute("aria-busy", "true");
      button.disabled = true;
      if (spinner) {
        spinner.hidden = false;
      }
      window.setTimeout(function () {
        button.removeAttribute("aria-busy");
        button.disabled = false;
        if (spinner) {
          spinner.hidden = true;
        }
        announce(t("comp.button.saved"));
      }, 900);
    });
  }

  function sanitizeAmountInput(value) {
    var cleaned = value.replace(/[^\d.,]/g, "");
    var firstSeparator = cleaned.search(/[.,]/);
    if (firstSeparator >= 0) {
      var head = cleaned.slice(0, firstSeparator + 1);
      var tail = cleaned.slice(firstSeparator + 1).replace(/[.,]/g, "");
      cleaned = head + tail;
    }
    return cleaned;
  }

  function initMoneyInputs() {
    $all("[data-money-input]").forEach(function (wrapper) {
      var input = $("input", wrapper);
      var preview = $("[data-money-preview]", wrapper);
      var error = $("[data-money-error]", wrapper);
      if (!input) {
        return;
      }
      input.addEventListener("input", function () {
        var cleaned = sanitizeAmountInput(input.value);
        if (cleaned !== input.value) {
          input.value = cleaned;
        }
        input.removeAttribute("aria-invalid");
        if (error) {
          error.hidden = true;
        }
        if (preview) {
          var cents = toCents(input.value);
          preview.textContent = cents !== null && cents > 0n ? formatMoney(input.value) : "";
        }
      });
    });
  }

  function setFieldError(wrapper, key) {
    var input = $("input", wrapper);
    var error = $("[data-money-error]", wrapper);
    if (!input || !error) {
      return;
    }
    input.setAttribute("aria-invalid", "true");
    error.textContent = t(key);
    error.hidden = false;
  }

  function clearFieldError(wrapper) {
    var input = $("input", wrapper);
    var error = $("[data-money-error]", wrapper);
    if (!input || !error) {
      return;
    }
    input.removeAttribute("aria-invalid");
    error.hidden = true;
    error.textContent = "";
  }

  function openDialog(dialog, trigger) {
    if (!dialog) {
      return;
    }
    lastDialogTrigger = trigger || (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    dialog.showModal();
    var initial =
      dialog.querySelector("[data-initial-focus]") ||
      dialog.querySelector("input, select, textarea, button, a[href]");
    if (initial) {
      initial.focus();
    }
  }

  function closeDialog(dialog) {
    if (dialog && dialog.open) {
      dialog.close();
    }
  }

  function initDialogs() {
    $all("[data-dialog-open]").forEach(function (button) {
      button.addEventListener("click", function () {
        openDialog(document.getElementById(button.getAttribute("data-dialog-open")), button);
      });
    });

    $all("dialog").forEach(function (dialog) {
      $all("[data-dialog-close]", dialog).forEach(function (button) {
        button.addEventListener("click", function () {
          if (dialog.getAttribute("data-busy") === "true") {
            return;
          }
          closeDialog(dialog);
        });
      });
      dialog.addEventListener("click", function (event) {
        if (
          event.target === dialog &&
          dialog.getAttribute("data-busy") !== "true" &&
          !dialog.hasAttribute("data-no-backdrop-close")
        ) {
          closeDialog(dialog);
        }
      });
      dialog.addEventListener("cancel", function (event) {
        if (dialog.getAttribute("data-busy") === "true") {
          event.preventDefault();
        }
      });
      dialog.addEventListener("close", function () {
        dialog.removeAttribute("data-busy");
        if (lastDialogTrigger && document.contains(lastDialogTrigger)) {
          lastDialogTrigger.focus();
        } else {
          var main = document.getElementById("main");
          if (main) {
            main.focus();
          }
        }
        lastDialogTrigger = null;
      });
    });
  }

  function copyText(value) {
    function fallback() {
      try {
        var area = document.createElement("textarea");
        area.value = value;
        area.setAttribute("readonly", "true");
        area.className = "sr-only";
        document.body.appendChild(area);
        area.select();
        var ok = document.execCommand("copy");
        document.body.removeChild(area);
        announce(t(ok ? "common.copied" : "common.copyFailed"));
      } catch (error) {
        announce(t("common.copyFailed"));
      }
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(function () {
        announce(t("common.copied"));
      }, fallback);
    } else {
      fallback();
    }
  }

  function initCopyButtons() {
    $all("[data-copy-target]").forEach(function (button) {
      button.addEventListener("click", function () {
        var target = document.querySelector(button.getAttribute("data-copy-target"));
        if (target) {
          copyText(target.textContent.trim());
        }
      });
    });
  }

  function initDemoNotes() {
    $all("[data-demo-note]").forEach(function (button) {
      button.addEventListener("click", function () {
        announce(t(button.getAttribute("data-demo-note")));
      });
    });
  }

  function initLockDialog() {
    var dialog = document.getElementById("lock-dialog");
    var openers = $all("[data-lock-open]");
    if (!dialog || openers.length === 0) {
      return;
    }
    var countdown = document.getElementById("lock-countdown");
    var title = document.getElementById("lock-title");
    var body = document.getElementById("lock-body");
    var continueButton = document.getElementById("lock-continue");
    var timer = null;
    var remaining = 60;
    var expired = false;

    function paint() {
      var minutes = Math.floor(Math.max(remaining, 0) / 60);
      var seconds = Math.max(remaining, 0) % 60;
      if (countdown) {
        countdown.textContent = String(minutes).padStart(2, "0") + ":" + String(seconds).padStart(2, "0");
      }
    }

    function stop() {
      if (timer !== null) {
        window.clearInterval(timer);
        timer = null;
      }
    }

    function expire() {
      expired = true;
      stop();
      if (title) {
        title.textContent = t("kas.lockExpiredTitle");
      }
      if (body) {
        body.textContent = t("kas.lockExpiredBody");
      }
      if (continueButton) {
        continueButton.textContent = t("kas.lockContinue");
      }
      announce(t("kas.lockExpiredAnnounce"));
    }

    function start() {
      stop();
      remaining = 60;
      expired = false;
      if (title) {
        title.textContent = t("kas.lockTitle");
      }
      if (body) {
        body.textContent = t("kas.lockBody");
      }
      if (continueButton) {
        continueButton.textContent = t("kas.lockContinue");
      }
      paint();
      timer = window.setInterval(function () {
        remaining -= 1;
        paint();
        if (remaining <= 0) {
          expire();
        }
      }, 1000);
    }

    openers.forEach(function (opener) {
      opener.addEventListener("click", function () {
        openDialog(dialog, opener);
        start();
        announce(t("kas.lockBody"));
      });
    });

    dialog.addEventListener("cancel", function (event) {
      event.preventDefault();
    });

    dialog.addEventListener("close", function () {
      stop();
    });

    if (continueButton) {
      continueButton.addEventListener("click", function () {
        if (expired) {
          closeDialog(dialog);
          announce(t("kas.lockExpiredAnnounce"));
          return;
        }
        stop();
        closeDialog(dialog);
        announce(t("kas.lockContinueAnnounce"));
      });
    }

    localeHooks.push(function () {
      if (!dialog.open) {
        return;
      }
      if (expired) {
        if (title) {
          title.textContent = t("kas.lockExpiredTitle");
        }
        if (body) {
          body.textContent = t("kas.lockExpiredBody");
        }
      } else {
        if (title) {
          title.textContent = t("kas.lockTitle");
        }
        if (body) {
          body.textContent = t("kas.lockBody");
        }
      }
      if (continueButton) {
        continueButton.textContent = t("kas.lockContinue");
      }
    });
  }

  /* ------------------------------------------------------------------ */
  /* Table helpers                                                       */
  /* ------------------------------------------------------------------ */

  function sortValue(row, key) {
    if (key === "amount") {
      return toCents(row.amount) || 0n;
    }
    if (key === "member") {
      return String(row.member || row.memberNo || "");
    }
    return String(row[key] || "");
  }

  function compareRows(a, b, key) {
    var left = sortValue(a, key);
    var right = sortValue(b, key);
    if (typeof left === "bigint" && typeof right === "bigint") {
      return left < right ? -1 : left > right ? 1 : 0;
    }
    return String(left).localeCompare(String(right), localeTag());
  }

  function sortRows(rows, key, direction) {
    var copy = rows.slice();
    copy.sort(function (a, b) {
      var result = compareRows(a, b, key);
      return direction === "asc" ? result : -result;
    });
    return copy;
  }

  function setAriaSort(table, key, direction) {
    $all("thead th", table).forEach(function (th) {
      if (th.getAttribute("data-column") === key) {
        th.setAttribute("aria-sort", direction === "asc" ? "ascending" : "descending");
      } else {
        th.removeAttribute("aria-sort");
      }
    });
  }

  function pagerButton(label, disabled, onClick, active, pageNumber) {
    var button = el("button", "btn btn--sm", label);
    button.type = "button";
    button.disabled = Boolean(disabled);
    if (active) {
      button.setAttribute("aria-current", "page");
    }
    if (pageNumber !== undefined) {
      button.setAttribute("data-page", String(pageNumber));
    }
    button.addEventListener("click", onClick);
    return button;
  }

  /* ------------------------------------------------------------------ */
  /* Gallery                                                             */
  /* ------------------------------------------------------------------ */

  var galleryRows = [];

  function buildGalleryRows() {
    var rows = [];
    var types = ["deposit", "deposit", "withdrawal"];
    var statuses = ["posted", "posted", "posted", "pending", "posted", "failed"];
    for (var index = 1; index <= 57; index += 1) {
      var minutes = 6 + index;
      var hour = 8 + Math.floor(minutes / 60);
      var minute = minutes % 60;
      rows.push({
        time: String(hour).padStart(2, "0") + ":" + String(minute).padStart(2, "0"),
        member: t("ph.member") + " " + String(index).padStart(2, "0"),
        type: types[index % types.length],
        amount: String(((index * 137000) % 900000) + 15000),
        status: statuses[index % statuses.length],
        reference: "TRX-" + String(index).padStart(4, "0")
      });
    }
    return rows;
  }

  function initGalleryTable() {
    var table = document.getElementById("gallery-table");
    if (!table) {
      return;
    }
    var tbody = document.getElementById("gallery-tbody");
    var total = document.getElementById("gallery-total");
    var range = document.getElementById("gallery-range");
    var pageLabel = document.getElementById("gallery-page");
    var pager = document.getElementById("gallery-pager");
    var search = document.getElementById("gallery-search");
    var statusFilter = document.getElementById("gallery-status");
    var count = document.getElementById("gallery-count");
    var clear = document.getElementById("gallery-clear");
    var pageSize = 8;
    var view = { sortKey: "time", direction: "asc", page: 1, query: "", status: "" };

    galleryRows = buildGalleryRows();

    function matches(row) {
      var query = view.query.trim().toLowerCase();
      var statusLabel = t("status." + row.status).toLowerCase();
      var typeLabel = t("type." + row.type).toLowerCase();
      var matchesQuery =
        query === "" ||
        row.member.toLowerCase().indexOf(query) >= 0 ||
        row.reference.toLowerCase().indexOf(query) >= 0 ||
        typeLabel.indexOf(query) >= 0 ||
        statusLabel.indexOf(query) >= 0;
      var matchesStatus = view.status === "" || row.status === view.status;
      return matchesQuery && matchesStatus;
    }

    function filtered() {
      return galleryRows.filter(matches);
    }

    function updateCount() {
      if (!count) {
        return;
      }
      var countValue = filtered().length;
      count.textContent = t("common.rows", { count: formatInt(countValue) });
    }

    function render() {
      var rows = sortRows(filtered(), view.sortKey, view.direction);
      var pageCount = Math.max(1, Math.ceil(rows.length / pageSize));
      if (view.page > pageCount) {
        view.page = pageCount;
      }
      var start = (view.page - 1) * pageSize;
      var visible = rows.slice(start, start + pageSize);

      tbody.replaceChildren();

      if (visible.length === 0) {
        var emptyRow = el("tr");
        var emptyCell = el("td");
        emptyCell.colSpan = 6;
        var empty = el("div", "empty-state");
        empty.appendChild(el("p", "empty-state__title", t("comp.empty.filteredTitle")));
        empty.appendChild(el("p", "empty-state__body", t("comp.empty.filteredBody")));
        var actions = el("div", "empty-state__actions");
        var reset = el("button", "btn btn--sm", t("common.clearFilters"));
        reset.type = "button";
        reset.addEventListener("click", function () {
          view.query = "";
          view.status = "";
          view.page = 1;
          if (search) {
            search.value = "";
          }
          if (statusFilter) {
            statusFilter.value = "";
          }
          render();
          updateCount();
          announce(t("common.clearFilters"));
        });
        actions.appendChild(reset);
        empty.appendChild(actions);
        emptyCell.appendChild(empty);
        emptyRow.appendChild(emptyCell);
        tbody.appendChild(emptyRow);
      } else {
        visible.forEach(function (row) {
          var tr = el("tr");
          tr.appendChild(el("td", "num", row.time));
          tr.appendChild(el("td", "", row.member));
          tr.appendChild(el("td", "", t("type." + row.type)));
          var amount = el("td", "money-cell");
          amount.appendChild(el("span", "money", formatMoney(row.amount)));
          tr.appendChild(amount);
          var status = el("td");
          status.appendChild(badge(row.status));
          tr.appendChild(status);
          tr.appendChild(el("td", "num", row.reference));
          tbody.appendChild(tr);
        });
      }

      var sum = visible.reduce(function (accumulator, row) {
        return accumulator + (toCents(row.amount) || 0n);
      }, 0n);
      if (total) {
        total.textContent = formatMoney(fromCents(sum));
      }

      var from = rows.length === 0 ? 0 : start + 1;
      var to = Math.min(start + pageSize, rows.length);
      var rangeText = t("common.rangeOf", {
        from: formatInt(from),
        to: formatInt(to),
        total: formatInt(rows.length)
      });
      if (range) {
        range.textContent = rangeText;
      }
      if (pageLabel) {
        pageLabel.textContent = t("common.pageOf", { page: formatInt(view.page), total: formatInt(pageCount) });
      }

      if (pager) {
        pager.replaceChildren();
        pager.appendChild(
          pagerButton(t("common.prev"), view.page === 1, function () {
            view.page -= 1;
            render();
            announce(t("common.pageAnnounce", { page: view.page, range: rangeText }));
          })
        );
        for (var page = 1; page <= pageCount; page += 1) {
          (function (pageNumber) {
            pager.appendChild(
              pagerButton(formatInt(pageNumber), false, function () {
                view.page = pageNumber;
                render();
                announce(t("common.pageAnnounce", { page: pageNumber, range: rangeText }));
              }, pageNumber === view.page, pageNumber)
            );
          })(page);
        }
        pager.appendChild(
          pagerButton(t("common.next"), view.page === pageCount, function () {
            view.page += 1;
            render();
            announce(t("common.pageAnnounce", { page: view.page, range: rangeText }));
          })
        );
      }

      setAriaSort(table, view.sortKey, view.direction);
    }

    function resort(key) {
      if (view.sortKey === key) {
        view.direction = view.direction === "asc" ? "desc" : "asc";
      } else {
        view.sortKey = key;
        view.direction = "asc";
      }
      view.page = 1;
      render();
      var columnKey = {
        time: "comp.table.colTime",
        member: "comp.table.colMember",
        amount: "comp.table.colAmount"
      }[key];
      announce(
        t("common.sorted", {
          column: t(columnKey),
          direction: t(view.direction === "asc" ? "common.asc" : "common.desc")
        })
      );
    }

    $all("[data-sort]", table).forEach(function (button) {
      button.addEventListener("click", function () {
        resort(button.getAttribute("data-sort"));
      });
    });

    var countTimer = null;
    if (search) {
      search.addEventListener("input", function () {
        view.query = search.value;
        view.page = 1;
        render();
        window.clearTimeout(countTimer);
        countTimer = window.setTimeout(updateCount, 400);
      });
      search.addEventListener("keydown", function (event) {
        if (event.key === "Enter") {
          event.preventDefault();
          updateCount();
        }
      });
    }

    if (statusFilter) {
      statusFilter.addEventListener("change", function () {
        view.status = statusFilter.value;
        view.page = 1;
        render();
        updateCount();
      });
    }

    function resetView() {
      view.query = "";
      view.status = "";
      view.page = 1;
      if (search) {
        search.value = "";
      }
      if (statusFilter) {
        statusFilter.value = "";
      }
      render();
      updateCount();
    }

    if (clear) {
      clear.addEventListener("click", function () {
        resetView();
        announce(t("common.clearFilters"));
      });
    }

    $all("[data-clear-gallery]").forEach(function (button) {
      button.addEventListener("click", function () {
        resetView();
        announce(t("common.clearFilters"));
      });
    });

    var reload = document.querySelector("[data-refresh-table]");
    if (reload) {
      reload.addEventListener("click", function () {
        reload.setAttribute("aria-busy", "true");
        reload.disabled = true;
        window.setTimeout(function () {
          galleryRows = buildGalleryRows();
          render();
          updateCount();
          reload.removeAttribute("aria-busy");
          reload.disabled = false;
          announce(t("comp.toolbar.reloaded"));
        }, 600);
      });
    }

    var densityButtons = $all("[data-density]");
    densityButtons.forEach(function (button) {
      button.addEventListener("click", function () {
        var dense = button.getAttribute("data-density") === "dense";
        table.classList.toggle("dense", dense);
        densityButtons.forEach(function (other) {
          other.setAttribute("aria-pressed", String(other === button));
        });
      });
    });

    localeHooks.push(function () {
      galleryRows = galleryRows.map(function (row) {
        var suffix = row.member.split(" ").pop();
        return Object.assign({}, row, { member: t("ph.member") + " " + suffix });
      });
      render();
      updateCount();
    });

    render();
    updateCount();
  }

  function initGalleryFilter() {
    var form = document.getElementById("filter-demo");
    if (!form) {
      return;
    }
    var search = document.getElementById("filter-demo-search");
    var status = document.getElementById("filter-demo-status");
    var count = document.getElementById("filter-demo-count");
    var items = $all("[data-filter-status]", form.parentNode);
    var timer = null;

    function apply() {
      var query = search.value.trim().toLowerCase();
      var wanted = status.value;
      items.forEach(function (item) {
        var text = item.textContent.toLowerCase();
        var matches =
          (query === "" || text.indexOf(query) >= 0) &&
          (wanted === "" || item.getAttribute("data-filter-status") === wanted);
        item.hidden = !matches;
      });
    }

    function updateCount() {
      var shown = items.filter(function (item) {
        return !item.hidden;
      }).length;
      if (count) {
        count.textContent = t("common.rows", { count: formatInt(shown) });
      }
    }

    function applyAndCount() {
      apply();
      updateCount();
    }

    search.addEventListener("input", function () {
      apply();
      window.clearTimeout(timer);
      timer = window.setTimeout(updateCount, 400);
    });
    status.addEventListener("change", applyAndCount);
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      applyAndCount();
    });
    localeHooks.push(applyAndCount);
    applyAndCount();
  }

  function initGalleryPager() {
    var list = document.getElementById("pager-list");
    if (!list) {
      return;
    }
    var items = $all("li", list);
    var nav = document.getElementById("pager-demo");
    var range = document.getElementById("pager-range");
    var pageSize = 4;
    var page = 1;
    var pageCount = Math.ceil(items.length / pageSize);

    function render() {
      items.forEach(function (item, index) {
        item.hidden = index < (page - 1) * pageSize || index >= page * pageSize;
      });
      var from = (page - 1) * pageSize + 1;
      var to = Math.min(page * pageSize, items.length);
      var text = t("common.rangeOf", {
        from: formatInt(from),
        to: formatInt(to),
        total: formatInt(items.length)
      });
      if (range) {
        range.textContent = text;
      }
      $all("[data-page]", nav).forEach(function (button) {
        var number = Number(button.getAttribute("data-page"));
        if (number === page) {
          button.setAttribute("aria-current", "page");
        } else {
          button.removeAttribute("aria-current");
        }
      });
      $all("[data-page-prev]", nav).forEach(function (button) {
        button.disabled = page === 1;
      });
      $all("[data-page-next]", nav).forEach(function (button) {
        button.disabled = page === pageCount;
      });
    }

    $all("[data-page]", nav).forEach(function (button) {
      button.addEventListener("click", function () {
        page = Number(button.getAttribute("data-page"));
        render();
        announce(t("common.pageAnnounce", { page: page, range: range.textContent }));
      });
    });
    $all("[data-page-prev]", nav).forEach(function (button) {
      button.addEventListener("click", function () {
        page = Math.max(1, page - 1);
        render();
        announce(t("common.pageAnnounce", { page: page, range: range.textContent }));
      });
    });
    $all("[data-page-next]", nav).forEach(function (button) {
      button.addEventListener("click", function () {
        page = Math.min(pageCount, page + 1);
        render();
        announce(t("common.pageAnnounce", { page: page, range: range.textContent }));
      });
    });
    localeHooks.push(render);
    render();
  }

  function initGalleryReview() {
    var panel = document.getElementById("gallery-review");
    if (!panel) {
      return;
    }
    var filled = $("[data-review-filled]", panel);
    var empty = $("[data-review-empty]", panel);
    var error = $("[data-review-error]", panel);
    var submit = $("[data-review-submit]", panel);
    var result = $("[data-review-result]", panel);
    var mode = "filled";

    function paint() {
      if (filled) {
        filled.hidden = mode !== "filled";
      }
      if (empty) {
        empty.hidden = mode !== "empty";
      }
      if (error) {
        error.hidden = mode !== "error";
      }
      $all("[data-review-mode]", panel).forEach(function (button) {
        button.setAttribute("aria-pressed", String(button.getAttribute("data-review-mode") === mode));
      });
    }

    $all("[data-review-mode]", panel).forEach(function (button) {
      button.addEventListener("click", function () {
        mode = button.getAttribute("data-review-mode");
        paint();
        if (result) {
          result.hidden = true;
        }
      });
    });

    if (submit) {
      submit.addEventListener("click", function () {
        if (mode !== "filled") {
          return;
        }
        submit.setAttribute("aria-busy", "true");
        submit.disabled = true;
        window.setTimeout(function () {
          submit.removeAttribute("aria-busy");
          submit.disabled = false;
          if (result) {
            result.hidden = false;
          }
          announce(t("comp.review.success"));
        }, 700);
      });
    }

    localeHooks.push(paint);
    paint();
  }

  function initGalleryDialog() {
    var dialog = document.getElementById("gallery-confirm");
    if (!dialog) {
      return;
    }
    var confirm = $("[data-confirm]", dialog);
    if (!confirm) {
      return;
    }
    confirm.addEventListener("click", function () {
      dialog.setAttribute("data-busy", "true");
      confirm.setAttribute("aria-busy", "true");
      confirm.disabled = true;
      window.setTimeout(function () {
        confirm.removeAttribute("aria-busy");
        confirm.disabled = false;
        dialog.removeAttribute("data-busy");
        closeDialog(dialog);
        announce(t("comp.dialog.done"));
      }, 800);
    });
  }

  function initGalleryError() {
    var button = document.getElementById("gallery-error-retry");
    if (!button) {
      return;
    }
    var block = document.getElementById("gallery-error");
    var success = document.getElementById("gallery-error-success");
    button.addEventListener("click", function () {
      button.setAttribute("aria-busy", "true");
      button.disabled = true;
      window.setTimeout(function () {
        button.removeAttribute("aria-busy");
        button.disabled = false;
        if (block) {
          block.hidden = true;
        }
        if (success) {
          success.hidden = false;
        }
        announce(t("comp.error.success"));
      }, 900);
    });
  }

  /* ------------------------------------------------------------------ */
  /* Kas workstation                                                     */
  /* ------------------------------------------------------------------ */

  function initKas() {
    var form = document.getElementById("kas-form");
    if (!form) {
      return;
    }

    var modeButtons = $all("[data-kas-mode]");
    var amountWrapper = document.getElementById("kas-amount-field");
    var amountInput = document.getElementById("kas-amount");
    var amountPreview = document.getElementById("kas-amount-preview");
    var amountError = document.getElementById("kas-amount-error");
    var narration = document.getElementById("kas-narration");
    var submit = document.getElementById("kas-submit");
    var submitLabel = document.getElementById("kas-submit-label");
    var formSummary = document.getElementById("kas-summary");
    var reviewFilled = document.getElementById("kas-review-filled");
    var reviewEmpty = document.getElementById("kas-review-empty");
    var reviewError = document.getElementById("kas-review-error");
    var reviewRef = document.getElementById("kas-review-ref");
    var reviewDirection = document.getElementById("kas-review-direction");
    var reviewBefore = document.getElementById("kas-review-before");
    var reviewAmount = document.getElementById("kas-review-amount");
    var reviewAfter = document.getElementById("kas-review-after");
    var balanceView = document.getElementById("kas-balance");
    var referenceView = document.getElementById("kas-reference");
    var sessionState = document.getElementById("session-state");
    var result = document.getElementById("kas-result");
    var liveTable = document.getElementById("session-tbody");
    var tableTotal = document.getElementById("session-total");
    var tableRange = document.getElementById("session-range");
    var tablePage = document.getElementById("session-page");
    var tablePrev = document.getElementById("session-prev");
    var tableNext = document.getElementById("session-next");
    var searchToggle = document.getElementById("session-search-toggle");
    var searchPanel = document.getElementById("session-search-panel");
    var searchInput = document.getElementById("session-search");
    var typeFilter = document.getElementById("session-type");
    var filterReset = document.getElementById("session-filter-reset");
    var resultCount = document.getElementById("session-count");
    var closedBanner = document.getElementById("session-closed");
    var reopen = document.getElementById("session-reopen");
    var closeCashDialog = document.getElementById("close-cash-dialog");
    var closeConfirm = document.getElementById("close-cash-confirm");
    var accountInput = document.getElementById("kas-account");
    var accountLoad = document.getElementById("kas-account-load");
    var accountStatus = document.getElementById("kas-account-status");
    var submitSpinner = document.getElementById("kas-spinner");
    var slipDialog = document.getElementById("slip-dialog");
    var slipBody = document.getElementById("slip-body");
    var slipPrint = document.getElementById("slip-print");
    var printArea = document.getElementById("print-receipt");

    var balanceCents = 100000000n;
    var referenceSequence = 129;
    var sessionOpen = true;
    var reviewMode = "filled";
    var page = 1;
    var pageSize = 5;
    var sortKey = "time";
    var sortDirection = "desc";
    var query = "";
    var typeValue = "";
    var lastSaved = null;

    var rows = [
      { time: "08:12", type: "deposit", memberNo: "01", amount: "250000", status: "posted", reference: "TRX-000121" },
      { time: "08:24", type: "withdrawal", memberNo: "02", amount: "100000", status: "posted", reference: "TRX-000122" },
      { time: "08:31", type: "deposit", memberNo: "03", amount: "500000", status: "posted", reference: "TRX-000123" },
      { time: "08:47", type: "withdrawal", memberNo: "04", amount: "75000", status: "posted", reference: "TRX-000124" },
      { time: "09:02", type: "deposit", memberNo: "05", amount: "1200000", status: "posted", reference: "TRX-000125" },
      { time: "09:18", type: "withdrawal", memberNo: "06", amount: "300000", status: "posted", reference: "TRX-000126" },
      { time: "09:35", type: "deposit", memberNo: "07", amount: "90000", status: "pending", reference: "TRX-000127" },
      { time: "09:51", type: "deposit", memberNo: "08", amount: "450000", status: "posted", reference: "TRX-000128" }
    ];

    function memberLabel(row) {
      return t("ph.member") + " " + row.memberNo;
    }

    function referenceFor(sequence) {
      return "TRX-" + String(sequence).padStart(6, "0");
    }

    function amountCents() {
      return toCents(amountInput ? amountInput.value : "");
    }

    function currentMode() {
      var pressed = modeButtons.filter(function (button) {
        return button.getAttribute("aria-pressed") === "true";
      })[0];
      return pressed ? pressed.getAttribute("data-kas-mode") : "deposit";
    }

    function paintHeader() {
      if (sessionState) {
        sessionState.replaceChildren();
        sessionState.className = "";
        var sessionBadge = badge(sessionOpen ? "active" : "closed");
        var sessionText = sessionBadge.lastChild;
        if (sessionText) {
          sessionText.textContent = t(sessionOpen ? "kas.sessionOpen" : "kas.sessionClosed");
        }
        sessionState.appendChild(sessionBadge);
      }
      if (closedBanner) {
        closedBanner.hidden = sessionOpen;
      }
      if (amountInput) {
        amountInput.disabled = !sessionOpen;
      }
      if (narration) {
        narration.disabled = !sessionOpen;
      }
      if (submit) {
        submit.disabled = !sessionOpen;
      }
      var closeButton = document.getElementById("close-cash-open");
      if (closeButton) {
        closeButton.disabled = !sessionOpen;
      }
      var reopenButton = document.getElementById("session-reopen");
      if (reopenButton) {
        reopenButton.disabled = sessionOpen;
      }
    }

    function paintReview() {
      var mode = currentMode();
      var cents = amountCents();
      var hasAmount = cents !== null && cents > 0n;
      var before = balanceCents;
      var after = mode === "deposit" ? before + (cents || 0n) : before - (cents || 0n);

      if (submitLabel) {
        submitLabel.textContent = t(mode === "deposit" ? "kas.submitDeposit" : "kas.submitWithdrawal");
      }
      if (reviewDirection) {
        reviewDirection.textContent = t(mode === "deposit" ? "type.deposit" : "type.withdrawal");
      }
      if (reviewBefore) {
        reviewBefore.textContent = formatMoney(fromCents(before));
      }
      if (reviewAmount) {
        var sign = mode === "deposit" ? "+" : "-";
        reviewAmount.textContent = sign + " " + formatMoney(fromCents(cents || 0n));
      }
      if (reviewAfter) {
        reviewAfter.textContent = formatMoney(fromCents(after));
      }

      var showFilled = reviewMode === "filled" && hasAmount;
      if (reviewFilled) {
        reviewFilled.hidden = !showFilled;
      }
      if (reviewEmpty) {
        reviewEmpty.hidden = !(reviewMode === "empty" || (reviewMode === "filled" && !hasAmount));
      }
      if (reviewError) {
        reviewError.hidden = reviewMode !== "error";
      }
      $all("[data-kas-review-mode]").forEach(function (button) {
        button.setAttribute("aria-pressed", String(button.getAttribute("data-kas-review-mode") === reviewMode));
      });
      if (submit) {
        submit.disabled = !sessionOpen || reviewMode === "error";
      }
    }

    function filteredRows() {
      return rows.filter(function (row) {
        var typeLabel = t("type." + row.type).toLowerCase();
        var text = (memberLabel(row) + " " + row.reference + " " + typeLabel).toLowerCase();
        var matchesQuery = query === "" || text.indexOf(query) >= 0;
        var matchesType = typeValue === "" || row.type === typeValue;
        return matchesQuery && matchesType;
      });
    }

    function paintTable() {
      var filtered = sortRows(filteredRows(), sortKey, sortDirection);
      var pageCount = Math.max(1, Math.ceil(filtered.length / pageSize));
      if (page > pageCount) {
        page = pageCount;
      }
      var start = (page - 1) * pageSize;
      var visible = filtered.slice(start, start + pageSize);
      if (liveTable) {
        liveTable.replaceChildren();
        if (visible.length === 0) {
          var tr = el("tr");
          var td = el("td");
          td.colSpan = 6;
          var empty = el("div", "empty-state");
          empty.appendChild(el("p", "empty-state__title", t("kas.searchEmptyTitle")));
          empty.appendChild(el("p", "empty-state__body", t("kas.searchEmptyBody")));
          var actions = el("div", "empty-state__actions");
          var reset = el("button", "btn btn--sm", t("common.clearFilters"));
          reset.type = "button";
          reset.addEventListener("click", function () {
            clearFilters();
          });
          actions.appendChild(reset);
          empty.appendChild(actions);
          td.appendChild(empty);
          tr.appendChild(td);
          liveTable.appendChild(tr);
        } else {
          visible.forEach(function (row) {
            var tr = el("tr");
            tr.appendChild(el("td", "num", row.time));
            tr.appendChild(el("td", "", t("type." + row.type)));
            tr.appendChild(el("td", "", memberLabel(row)));
            var amount = el("td", "money-cell");
            amount.appendChild(el("span", "money", formatMoney(row.amount)));
            tr.appendChild(amount);
            var status = el("td");
            status.appendChild(badge(row.status));
            tr.appendChild(status);
            var action = el("td");
            var button = el("button", "btn btn--sm", t("common.receipt"));
            button.type = "button";
            button.addEventListener("click", function () {
              openSlip(row, true);
            });
            action.appendChild(button);
            tr.appendChild(action);
            liveTable.appendChild(tr);
          });
        }
      }

      var sum = visible.reduce(function (accumulator, row) {
        return accumulator + (toCents(row.amount) || 0n);
      }, 0n);
      if (tableTotal) {
        tableTotal.textContent = formatMoney(fromCents(sum));
      }
      var from = filtered.length === 0 ? 0 : start + 1;
      var to = Math.min(start + pageSize, filtered.length);
      if (tableRange) {
        tableRange.textContent = t("common.rangeOf", {
          from: formatInt(from),
          to: formatInt(to),
          total: formatInt(filtered.length)
        });
      }
      if (tablePage) {
        tablePage.textContent = t("common.pageOf", { page: formatInt(page), total: formatInt(pageCount) });
      }
      if (tablePrev) {
        tablePrev.disabled = page === 1;
      }
      if (tableNext) {
        tableNext.disabled = page === pageCount;
      }
      var table = document.getElementById("session-table");
      if (table) {
        setAriaSort(table, sortKey, sortDirection);
      }
    }

    function updateResultCount() {
      if (resultCount) {
        resultCount.textContent = t("common.rows", { count: formatInt(filteredRows().length) });
      }
    }

    function paintAll() {
      paintHeader();
      paintReview();
      paintTable();
      updateResultCount();
      if (referenceView) {
        referenceView.value = referenceFor(referenceSequence);
      }
      if (balanceView) {
        balanceView.textContent = formatMoney(fromCents(balanceCents));
      }
      if (amountPreview && amountInput) {
        var previewCents = toCents(amountInput.value);
        amountPreview.textContent =
          previewCents !== null && previewCents > 0n ? formatMoney(amountInput.value) : "";
      }
    }

    function clearFilters() {
      query = "";
      typeValue = "";
      page = 1;
      if (searchInput) {
        searchInput.value = "";
      }
      if (typeFilter) {
        typeFilter.value = "";
      }
      paintTable();
      updateResultCount();
    }

    function loadAccount() {
      if (!accountInput || !accountLoad || !accountStatus) {
        return;
      }
      var digits = accountInput.value.replace(/\D/g, "");
      accountStatus.className = "hint";
      accountStatus.textContent = t("kas.loadingAccount");
      accountLoad.disabled = true;
      accountLoad.setAttribute("aria-busy", "true");
      window.setTimeout(function () {
        accountLoad.disabled = false;
        accountLoad.removeAttribute("aria-busy");
        if (digits.length === 10) {
          accountStatus.className = "hint";
          accountStatus.textContent = t("kas.accountLoaded");
        } else {
          accountStatus.className = "field-error";
          accountStatus.textContent = t("kas.accountNotFound");
        }
      }, 500);
    }

    if (accountLoad) {
      accountLoad.addEventListener("click", loadAccount);
    }
    if (accountInput) {
      accountInput.addEventListener("keydown", function (event) {
        if (event.key === "Enter") {
          event.preventDefault();
          loadAccount();
        }
      });
    }

    modeButtons.forEach(function (button) {
      button.addEventListener("click", function () {
        modeButtons.forEach(function (other) {
          other.setAttribute("aria-pressed", String(other === button));
        });
        reviewMode = "filled";
        paintReview();
      });
    });

    if (amountInput) {
      amountInput.addEventListener("input", function () {
        var cleaned = sanitizeAmountInput(amountInput.value);
        if (cleaned !== amountInput.value) {
          amountInput.value = cleaned;
        }
        amountInput.removeAttribute("aria-invalid");
        if (amountError) {
          amountError.hidden = true;
        }
        if (formSummary) {
          formSummary.hidden = true;
        }
        if (amountPreview) {
          var cents = toCents(amountInput.value);
          amountPreview.textContent = cents !== null && cents > 0n ? formatMoney(amountInput.value) : "";
        }
        if (reviewMode === "filled") {
          paintReview();
        }
      });
    }

    $all("[data-kas-review-mode]").forEach(function (button) {
      button.addEventListener("click", function () {
        reviewMode = button.getAttribute("data-kas-review-mode");
        paintReview();
      });
    });

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (!sessionOpen) {
        announce(t("kas.sessionLimit"));
        return;
      }
      var cents = amountCents();
      var rawAmount = amountInput ? amountInput.value : "";
      var valid = true;
      if (/[.,]\d{3,}/.test(rawAmount)) {
        setFieldError(amountWrapper, "kas.amountErrorPrecision");
        valid = false;
      } else if (!amountInput || cents === null || cents <= 0n) {
        setFieldError(amountWrapper, "kas.amountErrorZero");
        valid = false;
      } else if (currentMode() === "withdrawal" && cents > balanceCents) {
        setFieldError(amountWrapper, "kas.amountErrorFunds");
        valid = false;
      }
      if (!valid) {
        if (formSummary) {
          formSummary.hidden = false;
          formSummary.textContent = t("kas.errorSummary");
        }
        if (amountInput) {
          amountInput.focus();
        }
        return;
      }

      var mode = currentMode();
      var reference = referenceFor(referenceSequence);
      var narrationValue = narration ? narration.value.trim() : "";
      submit.setAttribute("aria-busy", "true");
      submit.disabled = true;
      if (submitSpinner) {
        submitSpinner.hidden = false;
      }
      form.setAttribute("aria-busy", "true");

      window.setTimeout(function () {
        var postedCents = cents;
        var row = {
          time: new Intl.DateTimeFormat("en-GB", {
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
            timeZone: "Asia/Jakarta"
          }).format(new Date()),
          type: mode,
          memberNo: String(rows.length + 1).padStart(2, "0"),
          amount: fromCents(postedCents),
          status: "posted",
          reference: reference,
          narration: narrationValue
        };
        balanceCents = mode === "deposit" ? balanceCents + postedCents : balanceCents - postedCents;
        rows.unshift(row);
        referenceSequence += 1;
        lastSaved = row;
        page = 1;
        sortKey = "time";
        sortDirection = "desc";

        form.removeAttribute("aria-busy");
        submit.removeAttribute("aria-busy");
        submit.disabled = false;
        if (submitSpinner) {
          submitSpinner.hidden = true;
        }
        reviewMode = "filled";
        if (amountInput) {
          amountInput.value = "";
        }
        if (narration) {
          narration.value = "";
        }
        if (amountPreview) {
          amountPreview.textContent = "";
        }
        clearFieldError(amountWrapper);

        paintAll();
        renderResult(row);
        announce(t("kas.savedBody", {
          ref: reference,
          amount: formatMoney(fromCents(balanceCents))
        }));
      }, 700);
    });

    function renderResult(row) {
      if (!result) {
        return;
      }
      result.hidden = false;
      result.replaceChildren();
      var alertBox = el("div", "alert alert--success");
      alertBox.appendChild(icon("check", "icon alert__icon"));
      var content = el("div");
      content.appendChild(el("p", "alert__title", t("kas.savedTitle")));
      content.appendChild(el("p", "alert__body", t("kas.savedBody", {
        ref: row.reference,
        amount: formatMoney(fromCents(balanceCents))
      })));
      var actions = el("div", "alert__actions");
      var printButton = el("button", "btn btn--sm", t("kas.printSlip"));
      printButton.type = "button";
      printButton.addEventListener("click", function () {
        openSlip(row, false);
      });
      var nextButton = el("button", "btn btn--sm", t("kas.nextTxn"));
      nextButton.type = "button";
      nextButton.addEventListener("click", function () {
        result.hidden = true;
        if (amountInput) {
          amountInput.focus();
        }
      });
      actions.appendChild(printButton);
      actions.appendChild(nextButton);
      content.appendChild(actions);
      alertBox.appendChild(content);
      result.appendChild(alertBox);
    }

    $all("[data-kas-sort]").forEach(function (button) {
      button.addEventListener("click", function () {
        var key = button.getAttribute("data-kas-sort");
        if (sortKey === key) {
          sortDirection = sortDirection === "asc" ? "desc" : "asc";
        } else {
          sortKey = key;
          sortDirection = "asc";
        }
        page = 1;
        paintTable();
        var columnKey = {
          time: "kas.colTime",
          member: "kas.colMember",
          amount: "kas.colAmount"
        }[key];
        announce(t("common.sorted", {
          column: t(columnKey),
          direction: t(sortDirection === "asc" ? "common.asc" : "common.desc")
        }));
      });
    });

    if (tablePrev) {
      tablePrev.addEventListener("click", function () {
        page = Math.max(1, page - 1);
        paintTable();
        announce(t("common.pageAnnounce", { page: page, range: tableRange.textContent }));
      });
    }
    if (tableNext) {
      tableNext.addEventListener("click", function () {
        var filtered = filteredRows();
        var pageCount = Math.max(1, Math.ceil(filtered.length / pageSize));
        page = Math.min(pageCount, page + 1);
        paintTable();
        announce(t("common.pageAnnounce", { page: page, range: tableRange.textContent }));
      });
    }

    if (searchToggle && searchPanel) {
      searchToggle.addEventListener("click", function () {
        var expanded = searchToggle.getAttribute("aria-expanded") === "true";
        searchToggle.setAttribute("aria-expanded", String(!expanded));
        searchPanel.hidden = expanded;
        if (!expanded && searchInput) {
          searchInput.focus();
        }
      });
    }

    if (searchInput) {
      var searchTimer = null;
      searchInput.addEventListener("input", function () {
        query = searchInput.value.toLowerCase();
        page = 1;
        paintTable();
        window.clearTimeout(searchTimer);
        searchTimer = window.setTimeout(updateResultCount, 400);
      });
    }

    if (typeFilter) {
      typeFilter.addEventListener("change", function () {
        typeValue = typeFilter.value;
        page = 1;
        paintTable();
        updateResultCount();
      });
    }
    if (filterReset) {
      filterReset.addEventListener("click", function () {
        clearFilters();
        announce(t("common.clearFilters"));
      });
    }

    function openSlip(row, isCopy) {
      if (!slipDialog || !slipBody) {
        return;
      }
      slipBody.replaceChildren(buildReceipt(row, isCopy));
      openDialog(slipDialog, document.activeElement);
    }

    function buildReceipt(row, isCopy) {
      var receipt = el("div", "receipt");
      var head = el("div", "receipt__head");
      head.appendChild(el("p", "receipt__title", t("kas.slipTitle")));
      head.appendChild(el("p", "receipt__meta", "KRAN · " + t("kas.branchValue")));
      receipt.appendChild(head);

      var facts = el("dl", "receipt__rows");
      function fact(labelKey, value, money) {
        var line = el("div", "receipt__row");
        line.appendChild(el("dt", "", t(labelKey)));
        line.appendChild(el("dd", money ? "money" : "", value));
        facts.appendChild(line);
      }
      fact("kas.slipDate", formatDate("2026-11-05"), false);
      fact("kas.slipTime", row.time + " WIB", false);
      fact("kas.slipMember", memberLabel(row), false);
      fact("kas.slipMemberNo", t("ph.memberNo") + " " + row.memberNo, false);
      fact("kas.slipAccount", "10000000" + row.memberNo, false);
      fact("kas.slipDirection", t("type." + row.type), false);
      fact("kas.slipAmount", formatMoney(row.amount), true);
      fact("kas.slipNote", row.narration || t("common.none"), false);
      fact("kas.slipCashier", t("kas.cashierValue"), false);
      fact("kas.slipRef", row.reference, false);
      receipt.appendChild(facts);

      var totalIn = rows.reduce(function (accumulator, item) {
        return item.type === "deposit" ? accumulator + (toCents(item.amount) || 0n) : accumulator;
      }, 0n);
      var totalOut = rows.reduce(function (accumulator, item) {
        return item.type === "withdrawal" ? accumulator + (toCents(item.amount) || 0n) : accumulator;
      }, 0n);

      var foot = el("div", "receipt__foot");
      if (isCopy) {
        foot.appendChild(el("p", "", t("kas.slipReprint")));
      }
      var totals = el("dl", "receipt__rows");
      var headingRow = el("div", "receipt__row");
      headingRow.appendChild(el("dt", "", t("kas.slipSession")));
      headingRow.appendChild(el("dd", "", ""));
      totals.appendChild(headingRow);
      function totalRow(labelKey, value) {
        var line = el("div", "receipt__row");
        line.appendChild(el("dt", "", t(labelKey)));
        line.appendChild(el("dd", "money", value));
        totals.appendChild(line);
      }
      totalRow("kas.slipCount", formatInt(rows.length));
      totalRow("kas.slipIn", formatMoney(fromCents(totalIn)));
      totalRow("kas.slipOut", formatMoney(fromCents(totalOut)));
      foot.appendChild(totals);
      receipt.appendChild(foot);
      return receipt;
    }

    if (slipPrint && printArea) {
      slipPrint.addEventListener("click", function () {
        printArea.replaceChildren();
        var receipt = slipBody ? slipBody.querySelector(".receipt") : null;
        if (!receipt) {
          return;
        }
        printArea.appendChild(receipt.cloneNode(true));
        document.body.classList.add("print-receipt-mode");
        window.print();
      });
      window.addEventListener("afterprint", function () {
        document.body.classList.remove("print-receipt-mode");
      });
    }

    if (closeConfirm && closeDialog) {
      closeConfirm.addEventListener("click", function () {
        closeCashDialog.setAttribute("data-busy", "true");
        closeConfirm.setAttribute("aria-busy", "true");
        closeConfirm.disabled = true;
        window.setTimeout(function () {
          closeConfirm.removeAttribute("aria-busy");
          closeConfirm.disabled = false;
          closeCashDialog.removeAttribute("data-busy");
          sessionOpen = false;
          closeCashDialog.close();
          paintHeader();
          announce(t("kas.closeDone"));
        }, 700);
      });
    }

    if (reopen) {
      reopen.addEventListener("click", function () {
        sessionOpen = true;
        paintAll();
        announce(t("kas.reopened"));
      });
    }

    /* Keep translated labels fresh when the locale changes. */
    localeHooks.push(function () {
      paintAll();
      if (result && !result.hidden && lastSaved) {
        renderResult(lastSaved);
      }
    });

    paintAll();
  }

  /* ------------------------------------------------------------------ */
  /* Boot                                                                */
  /* ------------------------------------------------------------------ */

  initSettings();
  initBadges();
  initSegments();
  initButtonDemo();
  initMoneyInputs();
  initDialogs();
  initCopyButtons();
  initDemoNotes();
  initLockDialog();
  initGalleryTable();
  initGalleryFilter();
  initGalleryPager();
  initGalleryReview();
  initGalleryDialog();
  initGalleryError();
  initKas();

  applyLocale(state.locale, false);
})();
