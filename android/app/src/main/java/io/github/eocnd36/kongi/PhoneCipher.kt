package io.github.eocnd36.kongi

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Mac의 PhoneCipher(ClaudeUsageCore/PhoneLink.swift)와 같은 봉인 형식: nonce(12) | 암호문 | 태그(16), AES-256-GCM.
 * 상자마다 용도(context)를 함께 인증해서 다른 용도의 상자를 바꿔 끼우지 못하게 합니다.
 */
class PhoneCipher(private val key: ByteArray) {
    init {
        require(key.size == KEY_SIZE)
    }

    fun seal(plaintext: ByteArray, context: ByteArray, nonce: ByteArray = randomNonce()): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(context)
        return nonce + cipher.doFinal(plaintext)
    }

    /** 키가 다르거나 내용이 바뀌었으면 예외를 던집니다. */
    fun open(box: ByteArray, context: ByteArray): ByteArray {
        require(box.size > NONCE_SIZE + 16)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, box, 0, NONCE_SIZE))
        cipher.updateAAD(context)
        return cipher.doFinal(box, NONCE_SIZE, box.size - NONCE_SIZE)
    }

    companion object {
        const val KEY_SIZE = 32
        const val NONCE_SIZE = 12

        val REQUEST: ByteArray = "kongi.request.v1".toByteArray()
        fun reply(requestNonce: ByteArray) = "kongi.reply.v1".toByteArray() + requestNonce
        fun event(requestNonce: ByteArray) = "kongi.event.v1".toByteArray() + requestNonce

        private val random = SecureRandom()
        fun randomNonce() = ByteArray(NONCE_SIZE).also { random.nextBytes(it) }
    }
}
