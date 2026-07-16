use rekindle_client::HandoffError;

fn classify(error: HandoffError) -> u8 {
    match error {
        HandoffError::Disabled => 0,
        HandoffError::Rejected => 1,
        HandoffError::InvalidPayload => 2,
        HandoffError::TooLarge => 3,
        HandoffError::Application => 4,
    }
}

fn main() {
    let _ = classify(HandoffError::Rejected);
}
