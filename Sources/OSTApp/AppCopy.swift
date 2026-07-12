import OSTCore

enum AppCopy {
    static func text(_ english: String, language: AppDisplayLanguage) -> String {
        switch language {
        case .english:
            return english
        case .chinese:
            return chinese[english] ?? english
        case .japanese:
            return japanese[english] ?? english
        case .korean:
            return korean[english] ?? english
        }
    }

    static func languageName(_ language: SupportedLanguage, displayLanguage: AppDisplayLanguage) -> String {
        let key: String
        switch language {
        case .english: key = "English"
        case .chineseSimplified: key = "Chinese (Simplified)"
        case .chineseTraditional: key = "Chinese (Traditional)"
        case .japanese: key = "Japanese"
        case .korean: key = "Korean"
        }
        return text(key, language: displayLanguage)
    }

    static func productLanguageName(_ language: SupportedLanguage, displayLanguage: AppDisplayLanguage) -> String {
        language.isChinese ? text("Chinese", language: displayLanguage)
            : languageName(language, displayLanguage: displayLanguage)
    }

    static func captureFailure(_ failure: CaptureFailure, language: AppDisplayLanguage) -> String {
        switch failure {
        case .permissionDenied: return text("System audio permission was denied.", language: language)
        case .permissionRevoked: return text("System audio permission was revoked.", language: language)
        case .outputDeviceUnavailable: return text("No audio output device is available.", language: language)
        case .unsupportedLanguage(let value):
            return text("This language is not supported:", language: language) + " " + languageName(value, displayLanguage: language)
        case .speechLanguagePackUnavailable(let value):
            return text("The transcription language pack is unavailable:", language: language) + " " + languageName(value, displayLanguage: language)
        case .translationLanguagePackUnavailable: return text("The translation language pack is not installed.", language: language)
        case .automaticModelMissing: return text("Download an MLX model to use automatic language detection.", language: language)
        case .unsupportedDetectedLanguage: return text("The detected language is outside the supported set.", language: language)
        case .silentInput: return text("No audible input was detected.", language: language)
        case .inferenceOverload: return text("Transcription is falling behind real time.", language: language)
        case .modelLoadFailed: return text("The selected local model could not be loaded.", language: language)
        case .audioSystem(let reason): return text("Audio system error:", language: language) + " " + reason
        }
    }

    private static let chinese: [String: String] = [
        "General": "通用", "Models": "模型", "Appearance": "外观", "Overlay": "悬浮字幕", "Privacy": "隐私",
        "Close": "关闭", "Cancel": "取消", "Start": "开始", "Stop": "停止", "Quit": "退出", "Settings…": "设置…",
        "App language": "应用语言", "English": "英语", "Chinese": "中文", "Chinese (Simplified)": "中文（简体）", "Chinese (Traditional)": "中文（繁体）", "Japanese": "日语", "Korean": "韩语",
        "Input language": "输入语言", "Target language": "目标语言", "Chinese script": "中文字体", "Simplified": "简体", "Traditional": "繁体", "Automatic detection (MLX ASR)": "自动检测（MLX ASR）",
        "Endpoint detection (EPD)": "语句结束检测（EPD）", "Silence interval": "静音间隔", "Transcription provider": "转写提供方", "Translation provider": "翻译提供方", "Experimental": "实验性",
        "Available models": "可用模型", "Download": "下载", "Resume": "继续", "Show in Finder": "在访达中显示", "Delete Downloaded Model": "删除已下载模型", "View license": "查看许可证", "Copyright and notices": "版权与声明",
        "Source transcript": "原文", "Confirmed translation": "已确认翻译", "Current translation preview": "当前翻译预览", "Text size": "文字大小", "Text color": "文字颜色", "Background": "背景", "Background color": "背景颜色", "Opacity": "不透明度",
        "Layout": "布局", "Window arrangement": "窗口布局", "Combined window": "合并窗口", "Separate transcript and translation": "分离原文与翻译", "Text alignment": "文字对齐", "Left": "左", "Center": "居中", "Right": "右", "Confirmed lines per area": "每个区域的已确认行数", "Window controls": "窗口控制", "Lock window and pass clicks through": "锁定窗口并穿透点击", "Reset overlay position and size": "重置悬浮字幕位置和大小", "Overlay window preview": "悬浮字幕窗口预览", "Transcript window": "原文窗口", "Translation window": "翻译窗口",
        "Permission": "权限", "Open System Audio Permission Settings": "打开系统音频权限设置", "Session files": "会话文件", "Save each session to text files": "将每个会话保存为文本文件", "Choose Folder…": "选择文件夹…", "Data stays on this Mac": "数据仅保留在此 Mac 上", "Allowed": "已允许", "Denied or revoked": "已拒绝或撤销", "Checked when capture starts": "开始录制时检查",
        "Waiting": "等待中", "Checking permission": "正在检查权限", "Preparing models": "正在准备模型", "Capturing": "正在录制", "Stopping": "正在停止", "Stopped": "已停止", "Detected:": "检测到：", "Show Overlay": "显示悬浮字幕", "Hide Overlay": "隐藏悬浮字幕", "Lock Overlay": "锁定悬浮字幕", "Unlock Overlay": "解锁悬浮字幕", "Restart Capture": "重新开始录制", "Memory pressure — using Apple Translation": "内存压力较大 — 正在使用 Apple Translation",
        "Choose a folder for session files": "选择会话文件夹", "Choose": "选择", "The selected folder could not be saved.": "无法保存所选文件夹。", "Session files could not be created in the selected folder.": "无法在所选文件夹中创建会话文件。",
        "System audio permission was denied.": "系统音频权限被拒绝。", "System audio permission was revoked.": "系统音频权限已撤销。", "No audio output device is available.": "没有可用的音频输出设备。", "The selected local model could not be loaded.": "无法载入所选本地模型。",
        "Download Model": "下载模型", "Agree to License and Download": "同意许可证并下载", "The model can be downloaded again later.": "以后可以重新下载此模型。", "Changes to the app language are applied immediately.": "应用语言更改会立即生效。", "%.1f sec": "%.1f 秒",
        "A pause stabilizes the current segment for translation. A short pause does not force a new visible line. Restart capture after changing this value.": "达到此静音时间后，当前片段会稳定并进行翻译。短暂停顿不会强制换行。更改后请重新开始录制。",
        "Provider and model changes apply when the next capture starts.": "提供方和模型更改将在下次开始录制时生效。", "MLX translation prompt": "MLX 翻译提示词", "Restore Default Prompt": "恢复默认提示词", "High memory": "高内存", "MLX ASR model": "MLX ASR 模型", "MLX translation model": "MLX 翻译模型",
        "A session starts when capture starts and ends when capture stops. Confirmed transcripts and translations are saved as separate text files. This setting is off by default.": "会话从开始录制持续到停止录制。已确认的原文和翻译会分别保存为文本文件。此设置默认关闭。", "No folder selected": "未选择文件夹",
        "OST processes audio, transcripts, and translations on this Mac. The app has no feature that uploads or sends your audio, transcript, translation, settings, or saved session files outside your computer.": "OST 在这台 Mac 上处理音频、原文和翻译。应用没有任何将音频、原文、翻译、设置或保存的会话文件上传或发送到电脑外部的功能。", "Internet access is used only when you choose to download a model. OST receives model files and does not send your content.": "仅当你选择下载模型时才使用网络。OST 只接收模型文件，不会发送你的内容。", "When Apple Translation is used, macOS may send Apple non-content technical information such as the app identifier and selected language pair. Your audio, transcript, and translation text are not included.": "使用 Apple Translation 时，macOS 可能会向 Apple 发送不包含翻译内容的技术信息，例如应用标识符和所选语言组合。你的音频、转写文本和翻译文本不包含在其中。",
        "Transcription results appear here.": "转写结果将显示在这里。", "Confirmed translation results appear here.": "已确认的翻译将显示在这里。", "The current transcription preview appears here.": "当前转写预览将显示在这里。", "The current translation preview appears here.": "当前翻译预览将显示在这里。", "Choose Start from the OST menu bar icon.\nTranscription results appear here.": "从菜单栏的 OST 图标中选择“开始”。\n转写结果将显示在这里。", "Choose Start from the OST menu bar icon.\nTranslation results appear here.": "从菜单栏的 OST 图标中选择“开始”。\n翻译结果将显示在这里。",
        "This example follows the selected window arrangement, confirmed line count, alignment, text styles, background color, and opacity.": "此示例会跟随所选的窗口布局、已确认行数、对齐方式、文字样式、背景颜色和不透明度。",
        "lines": "行", "Preview": "预览", "The notice could not be loaded.": "无法载入声明。", "Checked when the signed app runs": "运行签名应用时检查"
    ]

    private static let japanese: [String: String] = [
        "General": "一般", "Models": "モデル", "Appearance": "外観", "Overlay": "オーバーレイ", "Privacy": "プライバシー",
        "Close": "閉じる", "Cancel": "キャンセル", "Start": "開始", "Stop": "停止", "Quit": "終了", "Settings…": "設定…",
        "App language": "表示言語", "English": "英語", "Chinese": "中国語", "Chinese (Simplified)": "中国語（簡体字）", "Chinese (Traditional)": "中国語（繁体字）", "Japanese": "日本語", "Korean": "韓国語",
        "Input language": "入力言語", "Target language": "翻訳先言語", "Chinese script": "中国語の表記", "Simplified": "簡体字", "Traditional": "繁体字", "Automatic detection (MLX ASR)": "自動検出（MLX ASR）",
        "Endpoint detection (EPD)": "発話終了検出（EPD）", "Silence interval": "無音時間", "Transcription provider": "文字起こしプロバイダ", "Translation provider": "翻訳プロバイダ", "Experimental": "試験的",
        "Available models": "利用可能なモデル", "Download": "ダウンロード", "Resume": "再開", "Show in Finder": "Finderで表示", "Delete Downloaded Model": "ダウンロード済みモデルを削除", "View license": "ライセンスを表示", "Copyright and notices": "著作権と通知",
        "Source transcript": "文字起こし", "Confirmed translation": "確定した翻訳", "Current translation preview": "現在の翻訳プレビュー", "Text size": "文字サイズ", "Text color": "文字色", "Background": "背景", "Background color": "背景色", "Opacity": "不透明度",
        "Layout": "配置", "Window arrangement": "ウインドウ構成", "Combined window": "1つのウインドウ", "Separate transcript and translation": "原文と翻訳を分離", "Text alignment": "文字揃え", "Left": "左", "Center": "中央", "Right": "右", "Confirmed lines per area": "各領域の確定行数", "Window controls": "ウインドウ操作", "Lock window and pass clicks through": "ウインドウを固定してクリックを透過", "Reset overlay position and size": "位置とサイズをリセット", "Overlay window preview": "オーバーレイウインドウのプレビュー", "Transcript window": "文字起こしウインドウ", "Translation window": "翻訳ウインドウ",
        "Permission": "権限", "Open System Audio Permission Settings": "システムオーディオ権限設定を開く", "Session files": "セッションファイル", "Save each session to text files": "セッションごとにテキストファイルへ保存", "Choose Folder…": "フォルダを選択…", "Data stays on this Mac": "データはこのMac内に保持されます", "Allowed": "許可済み", "Denied or revoked": "拒否または取り消し済み", "Checked when capture starts": "キャプチャ開始時に確認",
        "Waiting": "待機中", "Checking permission": "権限を確認中", "Preparing models": "モデルを準備中", "Capturing": "キャプチャ中", "Stopping": "停止中", "Stopped": "停止しました", "Detected:": "検出：", "Show Overlay": "オーバーレイを表示", "Hide Overlay": "オーバーレイを隠す", "Lock Overlay": "オーバーレイを固定", "Unlock Overlay": "固定を解除", "Restart Capture": "キャプチャを再開", "Memory pressure — using Apple Translation": "メモリ負荷が高いためApple Translationを使用中",
        "Choose a folder for session files": "セッションファイルのフォルダを選択", "Choose": "選択", "The selected folder could not be saved.": "選択したフォルダを保存できませんでした。", "Session files could not be created in the selected folder.": "選択したフォルダにセッションファイルを作成できませんでした。",
        "System audio permission was denied.": "システムオーディオの権限が拒否されました。", "System audio permission was revoked.": "システムオーディオの権限が取り消されました。", "No audio output device is available.": "利用可能なオーディオ出力デバイスがありません。", "The selected local model could not be loaded.": "選択したローカルモデルを読み込めませんでした。",
        "Download Model": "モデルをダウンロード", "Agree to License and Download": "ライセンスに同意してダウンロード", "The model can be downloaded again later.": "モデルは後で再ダウンロードできます。", "Changes to the app language are applied immediately.": "表示言語の変更はすぐに反映されます。", "%.1f sec": "%.1f秒",
        "A pause stabilizes the current segment for translation. A short pause does not force a new visible line. Restart capture after changing this value.": "指定した無音時間で現在の区間を確定し翻訳します。短い間だけで強制改行はしません。変更後はキャプチャを再開してください。",
        "Provider and model changes apply when the next capture starts.": "プロバイダとモデルの変更は次回のキャプチャ開始時に反映されます。", "MLX translation prompt": "MLX翻訳プロンプト", "Restore Default Prompt": "既定のプロンプトに戻す", "High memory": "大容量メモリ", "MLX ASR model": "MLX ASRモデル", "MLX translation model": "MLX翻訳モデル",
        "A session starts when capture starts and ends when capture stops. Confirmed transcripts and translations are saved as separate text files. This setting is off by default.": "セッションはキャプチャ開始から停止までです。確定した文字起こしと翻訳を別々のテキストファイルに保存します。初期設定はオフです。", "No folder selected": "フォルダが選択されていません",
        "OST processes audio, transcripts, and translations on this Mac. The app has no feature that uploads or sends your audio, transcript, translation, settings, or saved session files outside your computer.": "OSTは音声、文字起こし、翻訳をこのMac上で処理します。音声、文字起こし、翻訳、設定、保存したセッションファイルをコンピュータ外へアップロードまたは送信する機能はありません。", "Internet access is used only when you choose to download a model. OST receives model files and does not send your content.": "モデルのダウンロードを選択した場合にのみインターネットを使用します。OSTはモデルファイルを受信するだけで、ユーザーの内容は送信しません。", "When Apple Translation is used, macOS may send Apple non-content technical information such as the app identifier and selected language pair. Your audio, transcript, and translation text are not included.": "Apple Translationの使用時、macOSはアプリ識別子や選択した言語の組み合わせなど、翻訳内容を含まない技術情報をAppleへ送信する場合があります。音声、文字起こし、翻訳文は含まれません。",
        "Transcription results appear here.": "文字起こし結果がここに表示されます。", "Confirmed translation results appear here.": "確定した翻訳結果がここに表示されます。", "The current transcription preview appears here.": "現在の文字起こしプレビューがここに表示されます。", "The current translation preview appears here.": "現在の翻訳プレビューがここに表示されます。", "Choose Start from the OST menu bar icon.\nTranscription results appear here.": "メニューバーのOSTアイコンから「開始」を選択してください。\n文字起こし結果がここに表示されます。", "Choose Start from the OST menu bar icon.\nTranslation results appear here.": "メニューバーのOSTアイコンから「開始」を選択してください。\n翻訳結果がここに表示されます。",
        "This example follows the selected window arrangement, confirmed line count, alignment, text styles, background color, and opacity.": "この例には、選択したウインドウ構成、確定行数、配置、文字スタイル、背景色、不透明度が反映されます。",
        "lines": "行", "Preview": "表示例", "The notice could not be loaded.": "通知を読み込めませんでした。", "Checked when the signed app runs": "署名済みアプリの実行時に確認"
    ]

    private static let korean: [String: String] = [
        "General": "일반", "Models": "모델", "Appearance": "외형", "Overlay": "오버레이", "Privacy": "개인정보",
        "Close": "닫기", "Cancel": "취소", "Start": "시작", "Stop": "중지", "Quit": "종료", "Settings…": "설정…",
        "App language": "App 표시 언어", "English": "영어", "Chinese": "중국어", "Chinese (Simplified)": "중국어(간체)", "Chinese (Traditional)": "중국어(번체)", "Japanese": "일본어", "Korean": "한국어",
        "Input language": "입력 언어", "Target language": "목표 언어", "Chinese script": "중국어 문자", "Simplified": "간체", "Traditional": "번체", "Automatic detection (MLX ASR)": "자동 감지 (MLX ASR)",
        "Endpoint detection (EPD)": "문장 끝 감지 (EPD)", "Silence interval": "무음 간격", "Transcription provider": "받아쓰기 공급자", "Translation provider": "번역 공급자", "Experimental": "실험적",
        "Available models": "사용 가능한 모델", "Download": "다운로드", "Resume": "재개", "Show in Finder": "Finder에서 보기", "Delete Downloaded Model": "다운로드한 모델 삭제", "View license": "라이선스 보기", "Copyright and notices": "저작권 및 고지",
        "Source transcript": "원문", "Confirmed translation": "확정 번역문", "Current translation preview": "현재 번역문 미리보기", "Text size": "글자 크기", "Text color": "글자색", "Background": "배경", "Background color": "배경색", "Opacity": "불투명도",
        "Layout": "배치", "Window arrangement": "창 구성", "Combined window": "한 창에 결합", "Separate transcript and translation": "원문·번역 분리", "Text alignment": "텍스트 정렬", "Left": "좌측", "Center": "가운데", "Right": "우측", "Confirmed lines per area": "영역별 확정 줄 수", "Window controls": "창 조절", "Lock window and pass clicks through": "잠금 및 클릭 통과", "Reset overlay position and size": "오버레이 위치와 크기 초기화", "Overlay window preview": "오버레이 창 미리보기", "Transcript window": "원문 창", "Translation window": "번역 창",
        "Permission": "권한", "Open System Audio Permission Settings": "시스템 오디오 권한 설정 열기", "Session files": "세션 기록", "Save each session to text files": "세션별 기록을 텍스트 파일로 저장", "Choose Folder…": "폴더 선택…", "Data stays on this Mac": "데이터는 이 Mac 안에만 보관됩니다", "Allowed": "허용됨", "Denied or revoked": "거부 또는 철회됨", "Checked when capture starts": "시작할 때 확인",
        "Waiting": "대기 중", "Checking permission": "권한 확인 중", "Preparing models": "모델 준비 중", "Capturing": "캡처 중", "Stopping": "중지 중", "Stopped": "중지됨", "Detected:": "감지:", "Show Overlay": "오버레이 표시", "Hide Overlay": "오버레이 숨기기", "Lock Overlay": "오버레이 잠금", "Unlock Overlay": "오버레이 잠금 해제", "Restart Capture": "캡처 재시작", "Memory pressure — using Apple Translation": "메모리 압박 — Apple Translation 사용 중",
        "Choose a folder for session files": "세션 기록 폴더 선택", "Choose": "선택", "The selected folder could not be saved.": "선택한 폴더를 저장하지 못했습니다.", "Session files could not be created in the selected folder.": "선택한 폴더에 세션 파일을 만들지 못했습니다.",
        "System audio permission was denied.": "시스템 오디오 권한이 거부되었습니다.", "System audio permission was revoked.": "시스템 오디오 권한이 철회되었습니다.", "No audio output device is available.": "사용 가능한 출력 장치가 없습니다.", "The selected local model could not be loaded.": "선택한 로컬 모델을 불러오지 못했습니다.",
        "Download Model": "모델 다운로드", "Agree to License and Download": "라이선스에 동의하고 다운로드", "The model can be downloaded again later.": "필요할 때 모델을 다시 다운로드할 수 있습니다.", "Changes to the app language are applied immediately.": "App 표시 언어 변경은 즉시 적용됩니다.", "%.1f sec": "%.1f초",
        "A pause stabilizes the current segment for translation. A short pause does not force a new visible line. Restart capture after changing this value.": "이 시간만큼 음성이 끊기면 현재 구간을 안정화해 번역합니다. 짧은 멈춤만으로 표시 줄을 강제로 바꾸지는 않습니다. 변경 후 캡처를 다시 시작하면 적용됩니다.",
        "Provider and model changes apply when the next capture starts.": "공급자와 모델 변경은 다음 캡처 시작부터 적용됩니다.", "MLX translation prompt": "MLX 번역 프롬프트", "Restore Default Prompt": "기본 프롬프트로 복원", "High memory": "고메모리", "MLX ASR model": "MLX ASR 모델", "MLX translation model": "MLX 번역 모델",
        "A session starts when capture starts and ends when capture stops. Confirmed transcripts and translations are saved as separate text files. This setting is off by default.": "세션은 캡처를 시작한 때부터 중지할 때까지입니다. 확정된 원문과 번역을 각각 별도 텍스트 파일로 저장합니다. 기본값은 꺼짐입니다.", "No folder selected": "선택한 폴더 없음",
        "OST processes audio, transcripts, and translations on this Mac. The app has no feature that uploads or sends your audio, transcript, translation, settings, or saved session files outside your computer.": "OST는 오디오, 원문, 번역을 이 Mac에서 처리합니다. 오디오, 원문, 번역, 설정 또는 저장한 세션 파일을 사용자의 컴퓨터 밖으로 업로드하거나 전송하는 기능이 존재하지 않습니다.", "Internet access is used only when you choose to download a model. OST receives model files and does not send your content.": "인터넷은 사용자가 모델 다운로드를 선택한 경우에만 사용됩니다. OST는 모델 파일만 받으며 사용자의 내용을 보내지 않습니다.", "When Apple Translation is used, macOS may send Apple non-content technical information such as the app identifier and selected language pair. Your audio, transcript, and translation text are not included.": "Apple Translation을 사용하면 macOS가 앱 식별자와 선택한 언어 쌍처럼 번역 내용을 포함하지 않는 기술 정보를 Apple에 보낼 수 있습니다. 오디오, 원문과 번역문은 포함되지 않습니다.",
        "Transcription results appear here.": "여기에 받아쓰기 결과가 표시됩니다.", "Confirmed translation results appear here.": "여기에 확정 번역 결과가 표시됩니다.", "The current transcription preview appears here.": "여기에 현재 받아쓰기 미리보기가 표시됩니다.", "The current translation preview appears here.": "여기에 현재 번역 미리보기가 표시됩니다.", "Choose Start from the OST menu bar icon.\nTranscription results appear here.": "메뉴 막대의 OST 아이콘에서 ‘시작’을 선택하세요.\n여기에 받아쓰기 결과가 표시됩니다.", "Choose Start from the OST menu bar icon.\nTranslation results appear here.": "메뉴 막대의 OST 아이콘에서 ‘시작’을 선택하세요.\n여기에 번역 결과가 표시됩니다.",
        "This example follows the selected window arrangement, confirmed line count, alignment, text styles, background color, and opacity.": "이 예시는 선택한 창 구성, 확정 줄 수, 정렬, 글자 스타일, 배경색과 불투명도를 반영합니다.",
        "lines": "줄", "Preview": "표시 예시", "The notice could not be loaded.": "고지 내용을 읽을 수 없습니다.", "Checked when the signed app runs": "서명된 앱 실행 시 확인"
    ]
}
