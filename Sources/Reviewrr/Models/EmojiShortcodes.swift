import Foundation

/// GitHub and GitLab both render `:shortcode:` as an emoji. Foundation's
/// markdown parser does not, so a review bot's `:stop_sign: **Logic Error**`
/// arrived with the colons showing.
///
/// ## Not the whole set, deliberately
///
/// GitHub supports well over a thousand shortcodes. This covers the ones
/// that actually appear in review conversation — severity and status markers
/// from bots, and the handful of reactions people type — because a table of
/// 1,800 entries is a large amount of code to carry for names nobody writes
/// in a pull request. An unrecognized shortcode is left exactly as written,
/// which is also what GitHub does with one it does not know, so the failure
/// mode is "you see the text you typed" rather than a mangled comment.
enum EmojiShortcodes {
    /// Replaces every recognized `:shortcode:` in `source`.
    ///
    /// Code spans are skipped: `` `:key:` `` is a literal in a sentence
    /// about a dictionary, not an emoji, and replacing inside backticks
    /// would corrupt quoted code. Callers pass prose only — fenced blocks
    /// are already separated by `MarkdownSegmenter` before this runs.
    static func replace(in source: String) -> String {
        guard source.contains(":") else { return source }

        var result = ""
        result.reserveCapacity(source.count)
        var remainder = Substring(source)

        while let open = remainder.firstIndex(of: ":") {
            // Anything before the colon is copied through, except that a
            // backtick run has to be carried across whole.
            let prefix = remainder[remainder.startIndex..<open]
            if let backtick = prefix.firstIndex(of: "`") {
                // Copy up to and including the code span, then continue
                // scanning after it.
                let spanStart = backtick
                let afterOpen = remainder.index(after: spanStart)
                if let spanEnd = remainder[afterOpen...].firstIndex(of: "`") {
                    result += remainder[remainder.startIndex...spanEnd]
                    remainder = remainder[remainder.index(after: spanEnd)...]
                    continue
                }
                // Unterminated span: nothing left to interpret.
                result += remainder
                return result
            }

            result += prefix
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: ":") else {
                // No closing colon; the rest is plain text.
                result += remainder[open...]
                return result
            }
            let name = String(remainder[afterOpen..<close])
            if let emoji = table[name] {
                result += emoji
                remainder = remainder[remainder.index(after: close)...]
            } else {
                // Not a shortcode we know. Emit the opening colon only, so a
                // later colon on the same line still gets a chance to open a
                // real one — "10:30 and :warning:" has to work.
                result.append(":")
                remainder = remainder[afterOpen...]
            }
        }

        result += remainder
        return result
    }

    static func emoji(for shortcode: String) -> String? {
        table[shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))]
    }

    /// Shortcode → emoji. Grouped by why it shows up in a review.
    static let table: [String: String] = [
        // Severity and verdicts — what a review bot leads a finding with.
        "stop_sign": "🛑",
        "warning": "⚠️",
        "information_source": "ℹ️",
        "bulb": "💡",
        "bug": "🐛",
        "beetle": "🪲",
        "boom": "💥",
        "fire": "🔥",
        "rotating_light": "🚨",
        "no_entry": "⛔️",
        "no_entry_sign": "🚫",
        "exclamation": "❗️",
        "heavy_exclamation_mark": "❗️",
        "question": "❓",
        "grey_question": "❔",
        "bangbang": "‼️",

        // Pass/fail, the second most common bot vocabulary.
        "white_check_mark": "✅",
        "heavy_check_mark": "✔️",
        "ballot_box_with_check": "☑️",
        "x": "❌",
        "negative_squared_cross_mark": "❎",
        "heavy_multiplication_x": "✖️",
        "o": "⭕️",
        "check": "✔️",

        // Status and progress.
        "hourglass": "⌛️",
        "hourglass_flowing_sand": "⏳",
        "clock1": "🕐",
        "alarm_clock": "⏰",
        "construction": "🚧",
        "hammer": "🔨",
        "hammer_and_wrench": "🛠",
        "wrench": "🔧",
        "gear": "⚙️",
        "recycle": "♻️",
        "arrows_counterclockwise": "🔄",
        "arrow_right": "➡️",
        "arrow_left": "⬅️",
        "arrow_up": "⬆️",
        "arrow_down": "⬇️",
        "zap": "⚡️",
        "rocket": "🚀",
        "sparkles": "✨",
        "tada": "🎉",
        "confetti_ball": "🎊",
        "trophy": "🏆",
        "medal": "🏅",

        // Robots and tools — bots identify themselves with these.
        "robot": "🤖",
        "robot_face": "🤖",
        "gear2": "⚙️",
        "microscope": "🔬",
        "mag": "🔍",
        "mag_right": "🔎",
        "telescope": "🔭",
        "test_tube": "🧪",
        "dna": "🧬",
        "gem": "💎",
        "package": "📦",
        "wastebasket": "🗑",
        "broom": "🧹",
        "soap": "🧼",
        "shield": "🛡",
        "lock": "🔒",
        "unlock": "🔓",
        "key": "🔑",
        "closed_lock_with_key": "🔐",

        // Documents and data.
        "memo": "📝",
        "pencil": "✏️",
        "pencil2": "✏️",
        "clipboard": "📋",
        "page_facing_up": "📄",
        "books": "📚",
        "book": "📖",
        "bookmark": "🔖",
        "label": "🏷",
        "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉",
        "bar_chart": "📊",
        "abacus": "🧮",
        "scroll": "📜",
        "link": "🔗",
        "paperclip": "📎",
        "pushpin": "📌",
        "round_pushpin": "📍",
        "calendar": "📅",
        "date": "📅",

        // People's reactions.
        "thumbsup": "👍",
        "+1": "👍",
        "thumbsdown": "👎",
        "-1": "👎",
        "eyes": "👀",
        "raised_hands": "🙌",
        "clap": "👏",
        "pray": "🙏",
        "muscle": "💪",
        "point_right": "👉",
        "point_left": "👈",
        "point_up": "☝️",
        "wave": "👋",
        "ok_hand": "👌",
        "handshake": "🤝",
        "heart": "❤️",
        "heartpulse": "💗",
        "sparkling_heart": "💖",
        "hearts": "♥️",
        "star": "⭐️",
        "star2": "🌟",
        "100": "💯",
        "sos": "🆘",

        // Faces, for the tone people actually use in review.
        "smile": "😄",
        "smiley": "😃",
        "grinning": "😀",
        "grin": "😁",
        "laughing": "😆",
        "joy": "😂",
        "rofl": "🤣",
        "sweat_smile": "😅",
        "wink": "😉",
        "blush": "😊",
        "slightly_smiling_face": "🙂",
        "upside_down_face": "🙃",
        "thinking": "🤔",
        "thinking_face": "🤔",
        "neutral_face": "😐",
        "expressionless": "😑",
        "confused": "😕",
        "worried": "😟",
        "cry": "😢",
        "sob": "😭",
        "sweat": "😓",
        "facepalm": "🤦",
        "shrug": "🤷",
        "grimacing": "😬",
        "sunglasses": "😎",
        "nerd_face": "🤓",
        "exploding_head": "🤯",
        "skull": "💀",
        "ghost": "👻",
        "alien": "👽",
        "poop": "💩",
        "hankey": "💩",
        "shipit": "🚢",
        "ship": "🚢",
        "anchor": "⚓️",
        "coffee": "☕️",
        "beer": "🍺",
        "pizza": "🍕",
        "cake": "🍰",
        "snake": "🐍",
        "octocat": "🐙",
        "penguin": "🐧",
        "apple": "🍎",
        "green_apple": "🍏",
        "seedling": "🌱",
        "leaves": "🍃",
        "snowflake": "❄️",
        "sunny": "☀️",
        "cloud": "☁️",
        "rainbow": "🌈",
        "moon": "🌙",
        "earth_africa": "🌍",
        "globe_with_meridians": "🌐",

        // Colour dots, which bots use for status legends.
        "red_circle": "🔴",
        "large_blue_circle": "🔵",
        "white_circle": "⚪️",
        "black_circle": "⚫️",
        "green_circle": "🟢",
        "yellow_circle": "🟡",
        "orange_circle": "🟠",
        "purple_circle": "🟣",
        "brown_circle": "🟤",
        "red_square": "🟥",
        "green_square": "🟩",
        "yellow_square": "🟨",
        "blue_square": "🟦",
        "white_large_square": "⬜️",
        "black_large_square": "⬛️",
    ]
}
