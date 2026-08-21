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
- **環境自檢**：沒有 Python 就自動裝，見下方說明
- 主程式純 `ctypes` + `tkinter`，沒有任何第三方相依

## 使用方式

只要有 Windows 就能跑，**不需要事先裝 Python**。

雙擊 `run.bat` 即可。第一次執行會先檢查環境，缺什麼就補什麼，然後啟動程式；
之後再執行就會直接啟動。

想單獨做環境檢查（例如剛換一台機器）就跑 `setup.bat`，它只安裝不啟動。

按下「鎖定為 ENG」或熱鍵 `Ctrl + Alt + E` 開始鎖定，再按一次解除。

### 遊戲是用系統管理員開的？

Windows 不允許低權限行程對高權限視窗送訊息。如果目標程式是以系統管理員身分執行，
本程式也要用同樣權限才壓得住 —— 這時改用 `run_as_admin.bat`。

## 環境自檢與自動安裝

`bootstrap.ps1` 負責在啟動前把環境準備好，流程如下。

**1. 找出可用的 Python** —— 依序試這些來源，第一個「版本 ≥ 3.8 且 import 得到
tkinter」的就採用：

| 順序 | 來源 |
| --- | --- |
| 1 | 官方啟動器 `py -3` |
| 2 | PATH 上的 `python.exe` |
| 3 | 登錄檔 `HKCU`/`HKLM` 的 `Python\PythonCore\*\InstallPath` |
| 4 | 常見安裝路徑（`%LocalAppData%\Programs\Python`、`C:\Python3*`、`Program Files`） |

判斷方式是實際跑一支探針腳本，讀它印出的版本、tkinter 匯入結果與
`sys.executable`，而不是看檔案存不存在 —— 這樣才擋得掉兩種常見的假貨：

- **Microsoft Store 的執行別名**：`WindowsApps\python.exe` 是 0 byte 的重解析點，
  執行它只會彈出商店頁面。腳本靠檔案大小直接跳過。
- **缺 tcl/tk 的 Python**：版本再新，沒有 tkinter 這支程式一樣開不起來。

**2. 缺的話自動安裝** —— 先試 `winget`（`--scope user`，不需要 UAC），版本 id
由新到舊試一輪；winget 不存在或全數失敗，才退回官網安裝檔：抓
`python.org/ftp/python/` 的目錄清單挑最新版，用 HEAD 確認檔案真的存在後下載，
以 `InstallAllUsers=0 PrependPath=1 Include_tcltk=1` 靜默安裝。安裝完會重新讀取
PATH 再偵測一次。

**3. 相依套件** —— 專案若有 `requirements.txt` 就用 pip 裝好（pip 不在就先跑
`ensurepip`）。目前主程式只用標準函式庫，所以這步通常直接略過。

**4. 寫入快取** —— 把選定的 `pythonw.exe` 路徑存進 `.ime-lock-python`，
`run.bat` 下次就跳過整套檢查直接啟動。快取失效（檔案被刪、Python 被移除、
出現 `requirements.txt`）會自動退回完整流程。

### 手動操作

```powershell
# 只檢查、不啟動
powershell -ExecutionPolicy Bypass -File bootstrap.ps1

# 忽略快取重新偵測，並重裝相依套件
powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Force

# 只偵測不安裝，缺東西就回報失敗（適合放進 CI）
powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -NoInstall
```

成功回傳 0，環境備妥失敗回傳 1。

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
| `bootstrap.ps1` | 環境自檢與自動安裝 |
| `run.bat` | 一般權限啟動 |
| `run_as_admin.bat` | 以系統管理員身分啟動 |
| `setup.bat` | 只做環境準備，不啟動程式 |
