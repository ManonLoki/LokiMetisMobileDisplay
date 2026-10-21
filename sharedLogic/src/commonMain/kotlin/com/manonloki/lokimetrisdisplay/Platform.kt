package com.manonloki.lokimetrisdisplay

interface Platform {
    val name: String
}

expect fun getPlatform(): Platform