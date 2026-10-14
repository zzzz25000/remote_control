package com.example.ble

/** Independent native epoch: Dart generations alone cannot distinguish replacement GATTs. */
internal class NativeSession {
    private var token = 0L
    private var identity: Any? = null
    var generation: Int = 0
        private set

    fun begin(generation: Int): Long {
        invalidate()
        this.generation = generation
        return token
    }

    fun attach(token: Long, identity: Any): Boolean {
        if (this.token != token || this.identity != null) return false
        this.identity = identity
        return true
    }

    fun matches(token: Long, identity: Any): Boolean =
        token == this.token && this.identity === identity

    fun invalidate() {
        token++
        identity = null
    }
}

/** All callers run on the bridge's main handler. */
internal class NativeCompletion {
    private var completed = false
    fun claim(): Boolean {
        if (completed) return false
        completed = true
        return true
    }
}
