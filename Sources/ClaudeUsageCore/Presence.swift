import Foundation

/// Mac 앞에 사람이 있는지로 휴대폰 알림을 정합니다 (Mac을 쓰는 중이면 휴대폰까지 울리지 않게).
///
/// - 잠금·화면 꺼짐, 또는 2분 동안 키보드·마우스 입력이 없으면 자리 비움 → 바로 보냄.
/// - 쓰는 중에 생긴 알림은 잠시 보류: 15분 안에 자리를 비우면(방금 일어나 나감) 그때 보냄.
/// - 답이 필요한 승인·질문은 쓰는 중이어도 2분 동안 답이 없으면 보냄 (다른 일에 빠져 못 본 경우).
public enum Presence {
    public static let awayAfter: Double = 120
    public static let answerWithin: Double = 120
    public static let holdFor: Double = 15 * 60

    public static func isAway(idle: Double, locked: Bool, displayAsleep: Bool) -> Bool {
        locked || displayAsleep || idle >= awayAfter
    }

    /// 승인·질문을 휴대폰에 띄울지
    public static func alertRequest(age: Double, away: Bool) -> Bool {
        away || age >= answerWithin
    }

    public enum Held: Equatable { case send, keep, drop }

    /// 쓰는 중이라 미뤄 둔 알림 (완료 등)
    public static func held(age: Double, away: Bool) -> Held {
        if age > holdFor { return .drop }
        return away ? .send : .keep
    }
}
