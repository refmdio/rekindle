use iced::Center;
use iced::widget::{Column, button, column, text};

#[derive(Default)]
pub struct Counter {
    value: i64,
}

#[derive(Debug, Clone, Copy)]
pub enum Message {
    Increment,
    Decrement,
}

impl Counter {
    fn update(&mut self, message: Message) {
        match message {
            Message::Increment => self.value += 1,
            Message::Decrement => self.value -= 1,
        }
    }

    fn view(&self) -> Column<'_, Message> {
        column![
            button("Increment").on_press(Message::Increment),
            text(self.value).size(50),
            button("Decrement").on_press(Message::Decrement)
        ]
        .padding(20)
        .align_x(Center)
    }
}

pub fn run() -> iced::Result {
    iced::run(Counter::update, Counter::view)
}

#[cfg(test)]
mod tests {
    use super::Counter;

    #[test]
    fn increments_the_counter() {
        let mut counter = Counter::default();
        let mut ui = iced_test::simulator(counter.view());

        ui.click("Increment")
            .expect("Increment button should exist");

        for message in ui.into_messages() {
            counter.update(message);
        }

        assert_eq!(counter.value, 1);
    }
}
