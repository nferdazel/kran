/**
 * Klien langganan peristiwa realtime (spec §19.1–§19.2, D-021).
 *
 * Kontrak transport ada di `packages/contracts/events/realtime-envelope.v1.schema.json`:
 *  - klien mengirim `{"type":"subscribe","topics":[…],"resumeFrom":"<id terakhir>"}`;
 *  - server mengirim `event` (peristiwa outbox), `subscribed`, `resync`, `error`.
 *
 * Reconnect memakai backoff dengan `resumeFrom` = id peristiwa terakhir yang diterima, sehingga
 * peristiwa yang terjadi saat koneksi putus tidak hilang (server memutar ulang dari outbox).
 * Bila server mengirim `resync` (replay melebihi batas), pemanggil menyegarkan lewat HTTP.
 * Handshake 401 = sesi mati; karena WebSocket tidak mengekspos status HTTP-nya, kondisi itu
 * disimpulkan lewat pemeriksaan sesi setelah koneksi tertutup.
 */

export type RealtimeState = "connecting" | "connected" | "reconnecting";

export interface RealtimeEventFrame {
  type: "event";
  id: string;
  topic: string;
  eventType: string;
  occurredAt: string;
  payload: unknown;
}

interface SubscribedFrame {
  type: "subscribed";
  topics: string[];
  denied: string[];
  resumed: number;
  replayLimit: number;
}

interface ResyncFrame {
  type: "resync";
  reason: string;
}

interface ErrorFrame {
  type: "error";
  code: string;
  i18nKey: string;
}

type ServerFrame = RealtimeEventFrame | SubscribedFrame | ResyncFrame | ErrorFrame;

export interface RealtimeHandlers {
  onEvent: (frame: RealtimeEventFrame) => void;
  onState: (state: RealtimeState) => void;
  /** `resync`: mulai ulang lewat HTTP sebelum berlangganan lagi (spec §19.2). */
  onResync: () => void;
  /** Sesi tidak lagi sah (handshake 401): UI harus kembali ke halaman login. */
  onUnauthorized: () => void;
}

export interface RealtimeClient {
  stop: () => void;
}

const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 10_000;

export function connectRealtime(topics: string[], handlers: RealtimeHandlers): RealtimeClient {
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const url = `${scheme}://${location.host}/api/v1/events/stream`;

  let socket: WebSocket | null = null;
  let stopped = false;
  let attempt = 0;
  let lastEventId: string | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  function scheduleReconnect(): void {
    if (stopped) return;
    attempt += 1;
    handlers.onState("reconnecting");
    const delay = Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** (attempt - 1));
    reconnectTimer = setTimeout(open, delay);
  }

  async function sessionAlive(): Promise<boolean> {
    try {
      const response = await fetch("/api/v1/auth/session", { credentials: "same-origin" });
      return response.status !== 401;
    } catch {
      // Kegagalan jaringan bukan bukti sesi mati: biarkan reconnect berjalan.
      return true;
    }
  }

  async function handleClose(): Promise<void> {
    if (stopped) return;
    if (!(await sessionAlive())) {
      stopped = true;
      handlers.onUnauthorized();
      return;
    }
    scheduleReconnect();
  }

  function open(): void {
    if (stopped) return;
    handlers.onState(attempt === 0 ? "connecting" : "reconnecting");
    const current = new WebSocket(url);
    socket = current;

    current.addEventListener("open", () => {
      attempt = 0;
      handlers.onState("connected");
      const message: { type: string; topics: string[]; resumeFrom?: string } = {
        type: "subscribe",
        topics,
      };
      if (lastEventId) message.resumeFrom = lastEventId;
      current.send(JSON.stringify(message));
    });

    current.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      let frame: ServerFrame;
      try {
        frame = JSON.parse(event.data) as ServerFrame;
      } catch {
        return;
      }
      if (frame.type === "event") {
        lastEventId = frame.id;
        handlers.onEvent(frame);
      } else if (frame.type === "resync") {
        handlers.onResync();
      }
      // `error`: kesalahan protokol non-fatal, koneksi dibiarkan terbuka.
    });

    current.addEventListener("close", () => {
      void handleClose();
    });
    // `error` selalu diikuti `close`; penanganan cukup di `close`.
    current.addEventListener("error", () => {});
  }

  open();

  return {
    stop(): void {
      stopped = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      socket?.close();
    },
  };
}
