package com.manonloki.lokimetrisdisplay.protocol

/** 在平台递归解析器之前检查严格JSON语法和有限深度，防止坏线帧终止应用worker。 */
object TerminalJsonBoundary {
    /** 仅接受一个完整对象，最多64层容器；长度由socket和缓存入口另行限制。 */
    fun validateObject(text: String) { Scanner(text).validate() }
    /** 只验证语法，不替代Rust会话校验、JSONObject类型映射或领域规则。 */
    private class Scanner(private val text: String) {
        private var index = 0
        /** 根必须是对象，尾部只接受JSON规定的四种空白。 */
        fun validate() { whitespace(); require(peek() == '{'); value(0); whitespace(); require(index == text.length) }
        /** 每次递归前检查容器深度，数万层嵌套在平台解析前确定失败。 */
        private fun value(depth: Int) {
            whitespace()
            when (peek()) {
                '{' -> {
                    require(depth < 64); index++; whitespace()
                    if (take('}')) return
                    do { whitespace(); string(); whitespace(); require(take(':')); value(depth + 1); whitespace() } while (take(','))
                    require(take('}'))
                }
                '[' -> {
                    require(depth < 64); index++; whitespace()
                    if (take(']')) return
                    do { value(depth + 1); whitespace() } while (take(','))
                    require(take(']'))
                }
                '"' -> string()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> number()
            }
        }
        /** 字符串只允许标准转义，禁止注释、单引号及未转义控制字符。 */
        private fun string() {
            require(take('"'))
            while (index < text.length) {
                val char = text[index++]
                if (char == '"') return
                require(char.code >= 32)
                if (char == '\\') {
                    require(index < text.length)
                    when (text[index++]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                        'u' -> { repeat(4) { require(index < text.length && text[index++] in "0123456789abcdefABCDEF") } }
                        else -> throw IllegalArgumentException("lan_json_invalid")
                    }
                }
            }
            throw IllegalArgumentException("lan_json_invalid")
        }
        /** JSON数字不接受前导零、NaN、加号开头或缺少数字的指数。 */
        private fun number() {
            take('-')
            if (!take('0')) { require(peek() in '1'..'9'); digits() }
            if (take('.')) { require(peek() in '0'..'9'); digits() }
            if (peek() == 'e' || peek() == 'E') { index++; if (!take('+')) take('-'); require(peek() in '0'..'9'); digits() }
        }
        /** 读取连续十进制数字，不进行可能溢出的数值转换。 */
        private fun digits() { while (peek() in '0'..'9') index++ }
        /** 固定字面量必须完整匹配，其后分隔符由父容器或根边界验证。 */
        private fun literal(value: String) { require(text.regionMatches(index, value, 0, value.length)); index += value.length }
        /** 越界使用非JSON哨兵，不从空输入读取字符。 */
        private fun peek(): Char = text.getOrNull(index) ?: '\u0000'
        /** 条件消费一个确切符号，失败不移动当前位置。 */
        private fun take(char: Char): Boolean = if (peek() == char) { index++; true } else false
        /** JSON空白严格限定，不接受JS或平台扩展空白。 */
        private fun whitespace() { while (peek() in " \t\r\n") index++ }
    }
}
