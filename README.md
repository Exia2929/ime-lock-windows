# IME Lock

把 Windows 輸入法鎖定在 **English (United States)** 的小工具。

打遊戲或用某些全螢幕程式時，輸入法常常被切回中文，一按鍵就跳出注音組字視窗。
這支程式在背景持續監看前景視窗，只要輸入法不是 en-US 就強制切回去，順便把 IME
關成英數模式。

> 只能在 Windows 上執行。**不需要事先安裝 Python** —— 沒有的話它會自己裝。

---

## 使用指南

### 1. 下載

到 <https://github.com/Exia2929/ime-lock-windows> ，按綠色的 **Code** 按鈕 →
**Download ZIP**。

### 2. 解壓縮

**一定要先解壓縮再執行。** 直接在 ZIP 裡點 `run.bat` 會失敗 —— Windows 只會把那
一個檔案丟到暫存資料夾，它就找不到旁邊的主程式了。

解壓縮前建議先做這一步，可以省掉之後的安全性警告：
右鍵點 ZIP → **內容** → 最下面勾選 **解除封鎖** → 確定。

### 3. 執行 `run.bat`

雙擊 `run.bat`。第一次會先跳出一個黑色視窗做環境檢查：

- **電腦已經有 Python** —— 一兩秒後主視窗就會出現。
- **沒有 Python** —— 它會自動下載安裝（約 30 MB，看網速大概幾分鐘），
  裝完直接啟動。這段需要網路連線，過程中不用管它。

> 如果跳出「Windows 已保護您的電腦」之類的警告，點 **其他資訊** → **仍要執行**。
> 這是因為檔案是從網路下載的，第 2 步的「解除封鎖」就是在避免這個。

### 4. 開始鎖定

按視窗上的 **鎖定為 ENG**，或按全域熱鍵 `Ctrl + Alt + E` —— 這組熱鍵在遊戲全螢幕
時一樣有效，不用切回桌面。

再按一次就解除。狀態列的「已修正 N 次」代表它幫你擋掉了幾次輸入法被切走。

### 5. 玩遊戲的時候

如果**遊戲是用系統管理員身分開的**，請改用 `run_as_admin.bat` 啟動。

Windows 不允許低權限程式去干涉高權限視窗，所以這種情況下一般權限的 IME Lock
壓不住它。判斷方法很簡單：鎖定中進遊戲卻還是會跳出注音，就是這個原因。

要關掉程式直接關視窗就好，不會留在背景。

---

## 常見問題

| 狀況 | 怎麼辦 |
| --- | --- |
| 黑色視窗閃一下就消失，主視窗沒出現 | 改點 `setup.bat`，它會停在畫面上顯示錯誤訊息 |
| 顯示找不到 Python，自動安裝也失敗 | 到 [python.org](https://www.python.org/downloads/windows/) 手動安裝（安裝選項裡的 tcl/tk 要保持勾選），再跑一次 `run.bat` |
| 熱鍵 `Ctrl + Alt + E` 沒反應 | 多半是被其他程式佔用了，直接用視窗上的按鈕即可 |
| 鎖定中，遊戲裡還是跳出注音 | 改用 `run_as_admin.bat` |
| 想確認環境有沒有問題 | 跑 `setup.bat`，它只做檢查不啟動程式 |

---

## 功能

- 一鍵切換鎖定／解除，狀態列會顯示目前已修正幾次
- 全域熱鍵 `Ctrl + Alt + E`，遊戲全螢幕時也能切換
- 解除鎖定時可還原原本使用的輸入法（可關閉）
- 系統若沒有安裝英文(美國)鍵盤配置，會自動載入一個
- 視窗置頂開關
- 環境自檢：沒有 Python 就自動裝
- 主程式純 `ctypes` + `tkinter`，沒有任何第三方相依

---

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

---

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
