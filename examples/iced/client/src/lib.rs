use iced::widget::{Column, button, column, container, row, space, text};
use iced::{Alignment, Background, Border, Center, Color, Element, Fill, Size};

const BACKGROUND: Color = Color::from_rgb8(248, 250, 252);
const BORDER: Color = Color::from_rgb8(226, 232, 240);
const TEXT: Color = Color::from_rgb8(15, 23, 42);
const MUTED: Color = Color::from_rgb8(100, 116, 139);
const SUBTLE: Color = Color::from_rgb8(148, 163, 184);
const ACCENT: Color = Color::from_rgb8(8, 145, 178);
const ACCENT_HOVERED: Color = Color::from_rgb8(14, 116, 144);

#[derive(Default)]
pub struct Example {
    count: u32,
}

#[derive(Debug, Clone, Copy)]
pub enum Message {
    Increment,
}

impl Example {
    fn update(&mut self, message: Message) {
        match message {
            Message::Increment => self.count += 1,
        }
    }

    fn view(&self) -> Element<'_, Message> {
        let header = row![
            container(text("R").size(18).color(Color::WHITE))
                .center_x(40)
                .center_y(40)
                .style(|_| container::Style::default()
                    .background(ACCENT)
                    .border(Border {
                        radius: 8.0.into(),
                        ..Border::default()
                    })),
            column![
                text("Rekindle + Iced").size(24).color(TEXT),
                text("One Rust client for web and desktop")
                    .size(14)
                    .color(MUTED)
            ]
            .spacing(2)
        ]
        .height(48)
        .spacing(12)
        .align_y(Alignment::Center);

        let counter = card(
            column![
                section_label("COUNTER"),
                text(format!("Count is {}", self.count))
                    .size(28)
                    .color(TEXT),
                button(container(text("Increment")).center(Fill))
                    .on_press(Message::Increment)
                    .width(112)
                    .height(44)
                    .padding(0)
                    .style(accent_button)
            ]
            .spacing(17),
            176,
        );

        let targets = card(
            column![
                section_label("TARGETS"),
                target("Web", "WebAssembly"),
                target("Desktop", "Native executable")
            ]
            .spacing(10),
            132,
        );

        let content = column![
            header,
            counter,
            targets,
            container(
                text("Edit client/src/lib.rs and save to rebuild")
                    .size(12)
                    .color(SUBTLE)
            )
            .width(Fill)
            .center_x(Fill)
        ]
        .width(Fill)
        .max_width(640)
        .spacing(24);

        container(content)
            .width(Fill)
            .height(Fill)
            .padding([40, 24])
            .center_x(Fill)
            .style(|_| container::Style::default().background(BACKGROUND))
            .into()
    }
}

fn card<'a>(content: Column<'a, Message>, height: impl Into<iced::Length>) -> Element<'a, Message> {
    container(content)
        .width(Fill)
        .height(height)
        .padding(24)
        .style(|_| {
            container::Style::default()
                .background(Color::WHITE)
                .border(Border {
                    color: BORDER,
                    width: 1.0,
                    radius: 12.0.into(),
                })
        })
        .into()
}

fn section_label(label: &str) -> Element<'_, Message> {
    text(label).size(11).color(MUTED).into()
}

fn target(name: &'static str, detail: &'static str) -> Element<'static, Message> {
    row![
        text(name).size(14).color(TEXT),
        space::horizontal(),
        text(detail).size(14).color(MUTED)
    ]
    .height(20)
    .align_y(Center)
    .into()
}

fn accent_button(_theme: &iced::Theme, status: button::Status) -> button::Style {
    let background = match status {
        button::Status::Hovered => ACCENT_HOVERED,
        _ => ACCENT,
    };

    button::Style {
        background: Some(Background::Color(background)),
        text_color: Color::WHITE,
        border: Border {
            radius: 22.0.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
}

pub fn run() -> iced::Result {
    iced::application(Example::default, Example::update, Example::view)
        .title("Rekindle + Iced")
        .window_size(Size::new(820.0, 600.0))
        .run()
}

#[cfg(test)]
mod tests {
    use super::Example;

    #[test]
    fn increments_the_counter() {
        let mut example = Example::default();
        let mut ui = iced_test::simulator(example.view());

        ui.click("Increment")
            .expect("Increment button should exist");

        for message in ui.into_messages() {
            example.update(message);
        }

        assert_eq!(example.count, 1);
    }
}
