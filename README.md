# IME Lock

把 Windows 輸入法鎖定在 **English (United States)** 的小工具。

打遊戲或用某些全螢幕程式時，輸入法常常被切回中文，一按鍵就跳出注音組字視窗。
這支程式在背景持續監看前景視窗，只要輸入法不是 en-US 就強制切回去，順便把 IME
關成英數模式。

## 功能

- 一鍵切換鎖定／解除，狀態列會顯示目前已修正幾次
- 全域熱鍵 `Ctrl + Alt + E`，遊戲全螢幕時也能切換
- 解除鎖定時可還原原本使用的輸入法（可關閉）
- 系統若沒有安裝英文(美國)鍵盤配置，會自動載入一個
- 視窗置頂開關
- 純 `ctypes` + `tkinter`，沒有任何第三方相依

## 需求

- Windows
- Python 3（安裝時要包含 tkinter，官方安裝檔預設就有）

## 使用方式

雙擊 `run.bat`，或直接執行：

```
pythonw ime_lock.pyw
```

按下「鎖定為 ENG」或熱鍵 `Ctrl + Alt + E` 開始鎖定，再按一次解除。

### 遊戲是用系統管理員開的？

Windows 不允許低權限行程對高權限視窗送訊息。如果目標程式是以系統管理員身分執行，
本程式也要用同樣權限才壓得住 —— 這時改用 `run_as_admin.bat`。

## 運作方式

背景執行緒每 120 毫秒檢查一次前景視窗：

1. `GetForegroundWindow` → `GetWindowThreadProcessId` → `GetKeyboardLayout`
   取得前景視窗目前的鍵盤配置
2. 不是 `0x0409` 就送 `WM_INPUTLANGCHANGEREQUEST` 切回英文
3. 再透過 `ImmGetDefaultIMEWnd` 拿到 IME 視窗，用 `WM_IME_CONTROL` 關掉
   open status 並把 conversion mode 設成英數 —— 有些遊戲即使配置已是 en-US，
   仍會留著開啟中的組字視窗

熱鍵跑在獨立執行緒的訊息迴圈裡接 `WM_HOTKEY`，透過 `queue` 通知 GUI，避免卡住
tkinter 的 event loop。

## 檔案

| 檔案 | 說明 |
| --- | --- |
| `ime_lock.pyw` | 主程式（GUI + 鎖定邏輯） |
| `run.bat` | 一般權限啟動 |
| `run_as_admin.bat` | 以系統管理員身分啟動 |
