use eframe::egui;

const BACKGROUND: egui::Color32 = egui::Color32::from_rgb(248, 250, 252);
const BORDER: egui::Color32 = egui::Color32::from_rgb(226, 232, 240);
const TEXT: egui::Color32 = egui::Color32::from_rgb(15, 23, 42);
const MUTED: egui::Color32 = egui::Color32::from_rgb(100, 116, 139);
const ACCENT: egui::Color32 = egui::Color32::from_rgb(37, 99, 235);

#[derive(Default, serde::Deserialize, serde::Serialize)]
#[serde(default)]
pub struct Example {
    count: u32,
}

impl Example {
    pub fn new(context: &eframe::CreationContext<'_>) -> Self {
        context.egui_ctx.set_theme(egui::ThemePreference::Light);

        context
            .storage
            .and_then(|storage| eframe::get_value(storage, eframe::APP_KEY))
            .unwrap_or_default()
    }

    fn card() -> egui::Frame {
        egui::Frame::new()
            .fill(egui::Color32::WHITE)
            .stroke(egui::Stroke::new(1.0, BORDER))
            .corner_radius(12)
            .inner_margin(24)
    }

    fn section_label(ui: &mut egui::Ui, text: &str) {
        ui.label(egui::RichText::new(text).color(MUTED).size(11.0).strong());
    }
}

impl eframe::App for Example {
    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, eframe::APP_KEY, self);
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(BACKGROUND))
            .show(ui, |ui| {
                let width = ui.available_width().min(640.0);
                let margin = (ui.available_width() - width) / 2.0;

                ui.horizontal(|ui| {
                    ui.add_space(margin);
                    ui.vertical(|ui| {
                        ui.spacing_mut().item_spacing.y = 0.0;
                        ui.set_width(width);
                        ui.add_space(40.0);

                        ui.horizontal(|ui| {
                            ui.spacing_mut().item_spacing.x = 12.0;
                            ui.set_min_height(48.0);
                            egui::Frame::new()
                                .fill(ACCENT)
                                .corner_radius(8)
                                .show(ui, |ui| {
                                    ui.allocate_ui_with_layout(
                                        egui::vec2(40.0, 40.0),
                                        egui::Layout::centered_and_justified(
                                            egui::Direction::LeftToRight,
                                        ),
                                        |ui| {
                                            ui.label(
                                                egui::RichText::new("R")
                                                    .color(egui::Color32::WHITE)
                                                    .size(18.0)
                                                    .strong(),
                                            );
                                        },
                                    );
                                });

                            ui.vertical(|ui| {
                                ui.spacing_mut().item_spacing.y = 2.0;
                                ui.label(
                                    egui::RichText::new("Rekindle + egui")
                                        .color(TEXT)
                                        .size(24.0)
                                        .strong(),
                                );
                                ui.label(
                                    egui::RichText::new("One Rust client for web and desktop")
                                        .color(MUTED),
                                );
                            });
                        });

                        ui.add_space(24.0);
                        Self::card().show(ui, |ui| {
                            ui.spacing_mut().item_spacing.y = 8.0;
                            ui.set_width(ui.available_width());
                            ui.set_min_height(128.0);
                            Self::section_label(ui, "COUNTER");
                            ui.add_space(10.0);
                            ui.label(
                                egui::RichText::new(format!("Count is {}", self.count))
                                    .color(TEXT)
                                    .size(28.0)
                                    .strong(),
                            );
                            ui.add_space(12.0);
                            if ui
                                .add_sized(
                                    egui::vec2(112.0, 44.0),
                                    egui::Button::new(
                                        egui::RichText::new("Increment")
                                            .color(egui::Color32::WHITE)
                                            .strong(),
                                    )
                                    .fill(ACCENT)
                                    .corner_radius(12),
                                )
                                .clicked()
                            {
                                self.count += 1;
                            }
                        });

                        ui.add_space(24.0);
                        Self::card().show(ui, |ui| {
                            ui.spacing_mut().item_spacing.y = 8.0;
                            ui.set_width(ui.available_width());
                            ui.set_min_height(84.0);
                            Self::section_label(ui, "TARGETS");
                            ui.add_space(8.0);
                            ui.horizontal(|ui| {
                                ui.strong("Web");
                                ui.with_layout(
                                    egui::Layout::right_to_left(egui::Align::Center),
                                    |ui| {
                                        ui.colored_label(MUTED, "WebAssembly");
                                    },
                                );
                            });
                            ui.add_space(8.0);
                            ui.horizontal(|ui| {
                                ui.strong("Desktop");
                                ui.with_layout(
                                    egui::Layout::right_to_left(egui::Align::Center),
                                    |ui| {
                                        ui.colored_label(MUTED, "Native executable");
                                    },
                                );
                            });
                        });

                        ui.add_space(24.0);
                        ui.vertical_centered(|ui| {
                            ui.label(
                                egui::RichText::new("Edit client/src/app.rs and save to rebuild")
                                    .color(egui::Color32::from_rgb(148, 163, 184))
                                    .size(12.0),
                            );
                        });
                    });
                });
            });
    }
}

#[cfg(test)]
mod tests {
    use super::Example;
    use egui_kittest::{Harness, kittest::Queryable};

    #[test]
    fn increments_the_counter() {
        let mut harness = Harness::new_eframe(|context| Example::new(context));

        harness.get_by_label("Increment").click();
        harness.run();

        assert_eq!(harness.state().count, 1);
    }
}
