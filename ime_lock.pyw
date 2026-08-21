# -*- coding: utf-8 -*-
"""IME Lock - 把輸入法鎖定在 English (United States)。

按下按鈕（或全域熱鍵 Ctrl+Alt+E）後，背景執行緒會持續監看前景視窗，
只要輸入法不是 en-US 就強制切回去，並把 IME 關成英數模式。
再按一次即解除鎖定。
"""

import ctypes
import queue
import threading
import time
import tkinter as tk
from ctypes import wintypes
from tkinter import ttk

user32 = ctypes.WinDLL("user32", use_last_error=True)
imm32 = ctypes.WinDLL("imm32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)

LANG_EN_US = 0x0409
WM_INPUTLANGCHANGEREQUEST = 0x0050
WM_IME_CONTROL = 0x0283
IMC_GETCONVERSIONMODE = 0x0001
IMC_SETCONVERSIONMODE = 0x0002
IMC_GETOPENSTATUS = 0x0005
IMC_SETOPENSTATUS = 0x0006
SMTO_ABORTIFHUNG = 0x0002
KLF_ACTIVATE = 0x0001

WM_HOTKEY = 0x0312
WM_QUIT = 0x0012
MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_NOREPEAT = 0x4000
VK_E = 0x45
HOTKEY_ID = 0xB001

POLL_INTERVAL = 0.12  # 秒

LRESULT = ctypes.c_ssize_t

user32.GetForegroundWindow.restype = wintypes.HWND
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetKeyboardLayout.argtypes = [wintypes.DWORD]
user32.GetKeyboardLayout.restype = ctypes.c_void_p
user32.GetKeyboardLayoutList.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
user32.GetKeyboardLayoutList.restype = ctypes.c_int
user32.LoadKeyboardLayoutW.argtypes = [wintypes.LPCWSTR, wintypes.UINT]
user32.LoadKeyboardLayoutW.restype = ctypes.c_void_p
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostMessageW.restype = wintypes.BOOL
user32.SendMessageTimeoutW.argtypes = [
    wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM,
    wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t),
]
user32.SendMessageTimeoutW.restype = LRESULT
user32.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
user32.RegisterHotKey.restype = wintypes.BOOL
user32.UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.GetMessageW.restype = ctypes.c_int
user32.PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
imm32.ImmGetDefaultIMEWnd.argtypes = [wintypes.HWND]
imm32.ImmGetDefaultIMEWnd.restype = wintypes.HWND


# ---------------------------------------------------------------- Win32 helpers

def is_admin():
    try:
        return bool(shell32.IsUserAnAdmin())
    except Exception:
        return False


def find_english_hkl():
    """找出已安裝的 en-US 鍵盤配置；沒有的話就載入一個。"""
    count = user32.GetKeyboardLayoutList(0, None)
    if count > 0:
        buf = (ctypes.c_void_p * count)()
        user32.GetKeyboardLayoutList(count, buf)
        for item in buf:
            hkl = item or 0
            if (hkl & 0xFFFF) == LANG_EN_US:
                return hkl, False
    hkl = user32.LoadKeyboardLayoutW("00000409", KLF_ACTIVATE) or 0
    return hkl, True


def foreground_layout():
    """回傳 (hwnd, hkl)。取不到時回 (0, 0)。"""
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return 0, 0
    tid = user32.GetWindowThreadProcessId(hwnd, None)
    if not tid:
        return hwnd, 0
    return hwnd, user32.GetKeyboardLayout(tid) or 0


def _ime_control(ime_hwnd, cmd, value=0):
    result = ctypes.c_size_t(0)
    ok = user32.SendMessageTimeoutW(
        ime_hwnd, WM_IME_CONTROL, cmd, value, SMTO_ABORTIFHUNG, 80, ctypes.byref(result)
    )
    return result.value if ok else None


def force_english(hwnd, current_hkl, en_hkl):
    """把前景視窗切成英文。回傳 True 表示這次有做出修正。"""
    acted = False

    if (current_hkl & 0xFFFF) != LANG_EN_US:
        user32.PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, en_hkl)
        acted = True

    # 即使配置已是 en-US，某些遊戲仍會留著開啟中的 IME 組字視窗，一併關掉。
    ime_hwnd = imm32.ImmGetDefaultIMEWnd(hwnd)
    if ime_hwnd:
        if _ime_control(ime_hwnd, IMC_GETOPENSTATUS):
            _ime_control(ime_hwnd, IMC_SETOPENSTATUS, 0)
            acted = True
        mode = _ime_control(ime_hwnd, IMC_GETCONVERSIONMODE)
        if mode:  # 0 = IME_CMODE_ALPHANUMERIC
            _ime_control(ime_hwnd, IMC_SETCONVERSIONMODE, 0)
            acted = True

    return acted


# ---------------------------------------------------------------- 背景鎖定執行緒

class Locker:
    def __init__(self, en_hkl, on_stat):
        self.en_hkl = en_hkl
        self.on_stat = on_stat
        self._stop = threading.Event()
        self._thread = None
        self.saved_hkl = 0
        self.fix_count = 0

    @property
    def active(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        if self.active:
            return
        _, self.saved_hkl = foreground_layout()
        self.fix_count = 0
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, restore=True):
        if not self.active:
            return
        self._stop.set()
        self._thread.join(timeout=1.0)
        self._thread = None
        if restore and self.saved_hkl and (self.saved_hkl & 0xFFFF) != LANG_EN_US:
            hwnd = user32.GetForegroundWindow()
            if hwnd:
                user32.PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, self.saved_hkl)

    def _run(self):
        while not self._stop.is_set():
            try:
                hwnd, hkl = foreground_layout()
                if hwnd and force_english(hwnd, hkl, self.en_hkl):
                    self.fix_count += 1
                    self.on_stat(self.fix_count)
            except Exception:
                pass  # 前景視窗剛好關閉之類的暫時性錯誤，下一輪重試
            self._stop.wait(POLL_INTERVAL)


# ---------------------------------------------------------------- 全域熱鍵執行緒

class HotkeyThread(threading.Thread):
    """獨立訊息迴圈接 WM_HOTKEY，透過 queue 通知 GUI。"""

    def __init__(self, events):
        super().__init__(daemon=True)
        self.events = events
        self.tid = 0
        self.ready = threading.Event()
        self.ok = False

    def run(self):
        self.tid = ctypes.windll.kernel32.GetCurrentThreadId()
        self.ok = bool(user32.RegisterHotKey(
            None, HOTKEY_ID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_E
        ))
        self.ready.set()
        if not self.ok:
            return
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_HOTKEY and msg.wParam == HOTKEY_ID:
                self.events.put("toggle")
        user32.UnregisterHotKey(None, HOTKEY_ID)

    def shutdown(self):
        if self.tid:
            user32.PostThreadMessageW(self.tid, WM_QUIT, 0, 0)


# ---------------------------------------------------------------- GUI

FONT = "Microsoft JhengHei UI"
BG = "#1e1f26"
FG = "#e6e6e6"
DIM = "#9aa0ac"
GREEN = "#3fbf6f"
RED = "#e05252"


class App:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()

        self.en_hkl, self.installed = find_english_hkl()
        self.locker = Locker(self.en_hkl, lambda n: self.events.put(("stat", n)))
        self.restore_var = tk.BooleanVar(value=True)
        self.topmost_var = tk.BooleanVar(value=True)

        self._build_ui()

        self.hotkey = HotkeyThread(self.events)
        self.hotkey.start()
        self.hotkey.ready.wait(timeout=1.0)
        if not self.hotkey.ok:
            self.hint.config(text="熱鍵 Ctrl+Alt+E 註冊失敗（可能被其他程式占用）")

        if not self.en_hkl:
            self.hint.config(text="找不到也無法載入 en-US 鍵盤配置，請先到系統設定新增英文(美國)")
            self.button.state(["disabled"])
        elif self.installed:
            self.hint.config(text="系統原本沒有英文(美國)，已自動載入")

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.after(80, self._pump)

    def _build_ui(self):
        r = self.root
        r.title("IME Lock")
        r.configure(bg=BG)
        r.resizable(False, False)
        r.attributes("-topmost", True)

        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Lock.TButton", font=(FONT, 13, "bold"), padding=10)
        style.configure("Opt.TCheckbutton", background=BG, foreground=DIM, font=(FONT, 9))
        style.map("Opt.TCheckbutton", background=[("active", BG)], foreground=[("active", FG)])

        tk.Label(r, text="輸入法鎖定", bg=BG, fg=FG, font=(FONT, 15, "bold")).pack(pady=(14, 2))
        tk.Label(r, text="English (United States) · 0x0409",
                 bg=BG, fg=DIM, font=("Consolas", 9)).pack()

        self.status = tk.Label(r, text="● 未鎖定", bg=BG, fg=DIM, font=(FONT, 12, "bold"))
        self.status.pack(pady=(12, 8))

        self.button = ttk.Button(r, text="鎖定為 ENG", style="Lock.TButton", command=self.toggle)
        self.button.pack(padx=24, fill="x")

        tk.Label(r, text="全域熱鍵：Ctrl + Alt + E（遊戲全螢幕時也有效）",
                 bg=BG, fg=DIM, font=(FONT, 9)).pack(pady=(10, 0))

        opts = tk.Frame(r, bg=BG)
        opts.pack(pady=(8, 0))
        ttk.Checkbutton(opts, text="解除時還原原本輸入法", variable=self.restore_var,
                        style="Opt.TCheckbutton").pack(anchor="w")
        ttk.Checkbutton(opts, text="視窗置頂", variable=self.topmost_var,
                        style="Opt.TCheckbutton", command=self.apply_topmost).pack(anchor="w")

        self.hint = tk.Label(r, text="", bg=BG, fg="#d8a657", font=(FONT, 9),
                             wraplength=300, justify="left")
        self.hint.pack(pady=(8, 0), padx=16)

        admin_note = "以系統管理員身分執行中" if is_admin() else \
                     "一般權限執行：若遊戲是用系統管理員開的，本程式也要用管理員身分執行才壓得住"
        tk.Label(r, text=admin_note, bg=BG, fg=DIM, font=(FONT, 8),
                 wraplength=300, justify="left").pack(pady=(6, 12), padx=16)

    def apply_topmost(self):
        self.root.attributes("-topmost", self.topmost_var.get())

    def toggle(self):
        if self.locker.active:
            self.locker.stop(restore=self.restore_var.get())
            self.status.config(text="● 未鎖定", fg=DIM)
            self.button.config(text="鎖定為 ENG")
            self.root.title("IME Lock")
        else:
            self.locker.start()
            self.status.config(text="● 鎖定中 (ENG)", fg=GREEN)
            self.button.config(text="解除鎖定")
            self.root.title("IME Lock — 鎖定中")

    def _pump(self):
        try:
            while True:
                item = self.events.get_nowait()
                if item == "toggle":
                    self.toggle()
                elif isinstance(item, tuple) and item[0] == "stat" and self.locker.active:
                    self.status.config(text=f"● 鎖定中 (ENG) · 已修正 {item[1]} 次", fg=GREEN)
        except queue.Empty:
            pass
        self.root.after(80, self._pump)

    def on_close(self):
        self.locker.stop(restore=self.restore_var.get())
        self.hotkey.shutdown()
        self.root.destroy()


def main():
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
