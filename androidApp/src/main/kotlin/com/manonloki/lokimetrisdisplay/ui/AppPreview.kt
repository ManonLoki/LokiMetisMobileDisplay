package com.manonloki.lokimetrisdisplay

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview

/** 预览不创建原生桥，也不伪造已同步的数据。 */
@Preview
@Composable
private fun DisplayPreview() {
    App(TerminalLinkView("12345678-1234-4abc-8def-123456789abc", MdnsProtocol.DEFAULT_NAME), {}, {}, { false }, {})
}
