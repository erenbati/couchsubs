// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Günlükteki tırnaklı, tek satırlık, en çok [limit] karakterlik alıntı (Mac/iPhone `SubtitleLog.excerpt`, Windows
 * `SubtitleLog.Excerpt` ile aynı biçim): satırlar " / " ile birleşir, uzunsa sonu "…".
 */
internal fun logExcerpt(text: String, limit: Int = 40): String {
    val flat = text.lines().map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" / ")
    val short = if (flat.length > limit) flat.take(limit - 1) + "…" else flat
    return "\"$short\""
}
