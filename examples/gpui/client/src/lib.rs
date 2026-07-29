use gpui::{
    App, Bounds, Context, Div, Render, Window, WindowBounds, WindowOptions, div, prelude::*, px,
    rgb, size,
};

pub struct Example {
    count: u32,
}

impl Example {
    fn card() -> Div {
        div()
            .flex()
            .flex_col()
            .w_full()
            .gap_3()
            .p_6()
            .rounded_xl()
            .border_1()
            .border_color(rgb(0xe2e8f0))
            .bg(rgb(0xffffff))
    }

    fn target(name: &'static str, detail: &'static str) -> Div {
        div()
            .flex()
            .w_full()
            .items_center()
            .justify_between()
            .h(px(20.0))
            .child(div().font_weight(gpui::FontWeight::SEMIBOLD).child(name))
            .child(div().text_sm().text_color(rgb(0x64748b)).child(detail))
    }
}

impl Render for Example {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .size_full()
            .justify_center()
            .bg(rgb(0xf8fafc))
            .text_color(rgb(0x0f172a))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .w(px(688.0))
                    .gap_6()
                    .px_6()
                    .py_10()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .h(px(48.0))
                            .gap_3()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .size_10()
                                    .rounded_lg()
                                    .bg(rgb(0xff6b35))
                                    .font_weight(gpui::FontWeight::BOLD)
                                    .text_color(rgb(0xffffff))
                                    .child("R"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(
                                        div()
                                            .text_2xl()
                                            .font_weight(gpui::FontWeight::BOLD)
                                            .child("Rekindle + GPUI"),
                                    )
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(rgb(0x64748b))
                                            .child("One Rust client for web and desktop"),
                                    ),
                            ),
                    )
                    .child(
                        Self::card()
                            .h(px(176.0))
                            .gap_2()
                            .child(
                                div()
                                    .text_xs()
                                    .font_weight(gpui::FontWeight::BOLD)
                                    .text_color(rgb(0x94a3b8))
                                    .child("COUNTER"),
                            )
                            .child(
                                div()
                                    .text_3xl()
                                    .font_weight(gpui::FontWeight::BOLD)
                                    .child(format!("Count is {}", self.count)),
                            )
                            .child(
                                div()
                                    .id("increment")
                                    .cursor_pointer()
                                    .self_start()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .w(px(112.0))
                                    .h(px(44.0))
                                    .rounded_full()
                                    .bg(rgb(0xea580c))
                                    .text_color(rgb(0xffffff))
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .hover(|style| style.bg(rgb(0xc2410c)))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.count += 1;
                                        cx.notify();
                                    }))
                                    .child("Increment"),
                            ),
                    )
                    .child(
                        Self::card()
                            .h(px(132.0))
                            .child(
                                div()
                                    .text_xs()
                                    .font_weight(gpui::FontWeight::BOLD)
                                    .text_color(rgb(0x94a3b8))
                                    .child("TARGETS"),
                            )
                            .child(Self::target("Web", "WebAssembly"))
                            .child(Self::target("Desktop", "Native executable")),
                    )
                    .child(
                        div()
                            .text_center()
                            .text_sm()
                            .text_color(rgb(0x94a3b8))
                            .child("Edit client/src/lib.rs and save to rebuild"),
                    ),
            )
    }
}

pub fn open(cx: &mut App) {
    let bounds = Bounds::centered(None, size(px(820.0), px(600.0)), cx);

    cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            ..Default::default()
        },
        |_, cx| cx.new(|_| Example { count: 0 }),
    )
    .expect("failed to open the application window");

    cx.activate(true);
}

#[cfg(test)]
mod tests {
    use gpui::TestAppContext;

    #[gpui::test]
    fn opens_the_application_window(cx: &mut TestAppContext) {
        cx.update(super::open);
    }
}
