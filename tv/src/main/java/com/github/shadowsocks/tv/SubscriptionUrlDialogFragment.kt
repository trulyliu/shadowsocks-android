/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2026                                                         *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *******************************************************************************/

package com.github.shadowsocks.tv

import android.os.Bundle
import android.text.InputType
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.leanback.preference.LeanbackEditTextPreferenceDialogFragmentCompat

/**
 * EditTextPreference dialog tuned for long URL entry on TV.
 *
 * The default Leanback dialog uses a single-line EditText, so a long
 * subscription URL scrolls off the left edge and the user only sees the trailing
 * query string. Adding `TYPE_TEXT_FLAG_MULTI_LINE` makes it wrap, but turns the
 * IME's primary action key into a newline insert — there is then no clear way
 * to confirm the entry on a TV remote.
 *
 * This subclass keeps the input type as plain `TYPE_TEXT_VARIATION_URI` (so the
 * IME's primary key stays as `IME_ACTION_DONE`) and forces the EditText to wrap
 * visually via `setSingleLine(false) + setHorizontallyScrolling(false) +
 * setMaxLines(N)`. Pressing Done — or BACK — saves and dismisses, matching the
 * Leanback EditTextPreference convention.
 */
class SubscriptionUrlDialogFragment : LeanbackEditTextPreferenceDialogFragmentCompat() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View? {
        val view = super.onCreateView(inflater, container, savedInstanceState)
        view?.findViewById<EditText>(android.R.id.edit)?.apply {
            // Wrap visually without enabling the IME's newline-on-Enter behavior.
            setSingleLine(false)
            setHorizontallyScrolling(false)
            maxLines = 6
            // setRawInputType (not setInputType) so it doesn't reset singleLine.
            setRawInputType(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
            imeOptions = EditorInfo.IME_ACTION_DONE
            // Do NOT call setOnEditorActionListener — Leanback's super already
            // installed its own listener that handles IME_ACTION_DONE by saving
            // and dismissing. Overriding it would break the commit path.
            // Cursor at the start so the user sees the URL from the host.
            setSelection(0)
        }
        return view
    }
}
