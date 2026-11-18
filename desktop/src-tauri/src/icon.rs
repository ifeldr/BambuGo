//! Icona nel tray: riquadro colorato con la stampante stilizzata (come su Mac).
//! L'oggetto sul piatto cresce con l'avanzamento; un pallino indica pausa, fine o problemi.

#[derive(Clone, Copy, PartialEq)]
pub enum Badge {
    None,
    Pause,
    Done,
    Failed,
    Warning,
}

const SIZE: usize = 64;

struct Canvas {
    px: Vec<u8>,
}

impl Canvas {
    fn new() -> Self {
        Canvas { px: vec![0; SIZE * SIZE * 4] }
    }

    /// Disegna con copertura `a` (0…1) sopra quanto già presente.
    fn blend(&mut self, x: i32, y: i32, rgb: [u8; 3], a: f32) {
        if x < 0 || y < 0 || x >= SIZE as i32 || y >= SIZE as i32 || a <= 0.0 {
            return;
        }
        let i = (y as usize * SIZE + x as usize) * 4;
        let a = a.min(1.0);
        let dst_a = self.px[i + 3] as f32 / 255.0;
        let out_a = a + dst_a * (1.0 - a);
        for c in 0..3 {
            let src = rgb[c] as f32;
            let dst = self.px[i + c] as f32;
            let v = if out_a > 0.0 { (src * a + dst * dst_a * (1.0 - a)) / out_a } else { 0.0 };
            self.px[i + c] = v.round() as u8;
        }
        self.px[i + 3] = (out_a * 255.0).round() as u8;
    }

    /// Rettangolo arrotondato pieno, con bordi sfumati.
    fn rounded_rect(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, r: f32, rgb: [u8; 3], alpha: f32) {
        for y in 0..SIZE {
            for x in 0..SIZE {
                let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                let cx = px.clamp(x0 + r, x1 - r);
                let cy = py.clamp(y0 + r, y1 - r);
                let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - r;
                let cover = (0.5 - d).clamp(0.0, 1.0);
                self.blend(x as i32, y as i32, rgb, cover * alpha);
            }
        }
    }

    fn rect_outline(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, r: f32, w: f32, rgb: [u8; 3]) {
        for y in 0..SIZE {
            for x in 0..SIZE {
                let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                let cx = px.clamp(x0 + r, x1 - r);
                let cy = py.clamp(y0 + r, y1 - r);
                let d = (((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - r).abs() - w / 2.0;
                let cover = (0.5 - d).clamp(0.0, 1.0);
                self.blend(x as i32, y as i32, rgb, cover);
            }
        }
    }

    fn circle(&mut self, cx: f32, cy: f32, r: f32, rgb: [u8; 3]) {
        for y in 0..SIZE {
            for x in 0..SIZE {
                let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt() - r;
                self.blend(x as i32, y as i32, rgb, (0.5 - d).clamp(0.0, 1.0));
            }
        }
    }
}

/// Colore di sfondo secondo lo stato.
pub fn state_color(state: &str, connected: bool, has_data: bool) -> [u8; 3] {
    if !connected || !has_data {
        return [130, 136, 145];
    }
    match state {
        "RUNNING" | "PREPARE" | "SLICING" => [31, 140, 219],
        "PAUSE" => [214, 163, 17],
        "FINISH" => [48, 170, 88],
        "FAILED" => [214, 60, 60],
        _ => [26, 189, 143],
    }
}

/// Restituisce i pixel RGBA (64×64).
pub fn draw(background: [u8; 3], progress: Option<f64>, badge: Badge, dimmed: bool) -> (Vec<u8>, u32, u32) {
    let mut c = Canvas::new();
    let s = SIZE as f32;
    let white = [255, 255, 255];

    c.rounded_rect(2.0, 2.0, s - 2.0, s - 2.0, 13.0, background, if dimmed { 0.6 } else { 1.0 });

    // telaio
    c.rect_outline(13.0, 13.0, 51.0, 51.0, 5.0, 3.2, white);
    // asse X
    c.rounded_rect(14.0, 22.0, 50.0, 25.0, 1.0, white, 1.0);
    // testina
    c.rounded_rect(27.0, 19.0, 37.0, 29.0, 2.0, white, 1.0);
    // piatto
    c.rounded_rect(18.0, 44.0, 46.0, 47.0, 1.0, white, 1.0);
    // oggetto in stampa: cresce con l'avanzamento
    let p = progress.unwrap_or(0.0).clamp(0.0, 1.0) as f32;
    if progress.is_some() {
        let height = 2.0 + 12.0 * p;
        c.rounded_rect(25.0, 44.0 - height, 39.0, 44.0, 1.5, white, 0.85);
    }

    let badge_color = match badge {
        Badge::None => None,
        Badge::Pause => Some([255, 196, 0]),
        Badge::Done => Some([52, 199, 89]),
        Badge::Failed => Some([255, 59, 48]),
        Badge::Warning => Some([255, 149, 0]),
    };
    if let Some(color) = badge_color {
        c.circle(51.0, 51.0, 12.0, [255, 255, 255]);
        c.circle(51.0, 51.0, 9.5, color);
    }
    (c.px, SIZE as u32, SIZE as u32)
}

#[cfg(test)]
mod tests {
    /// ICON_OUT=<cartella> cargo test icon -- salva le icone per controllarle a occhio.
    #[test]
    fn icon_samples() {
        let Ok(dir) = std::env::var("ICON_OUT") else { return };
        let cases = [
            ("idle", super::state_color("IDLE", true, true), None, super::Badge::None, false),
            ("running", super::state_color("RUNNING", true, true), Some(0.45), super::Badge::None, false),
            ("pause", super::state_color("PAUSE", true, true), Some(0.6), super::Badge::Pause, false),
            ("done", super::state_color("FINISH", true, true), Some(1.0), super::Badge::Done, false),
            ("failed", super::state_color("FAILED", true, true), None, super::Badge::Failed, false),
            ("offline", super::state_color("", false, false), None, super::Badge::Warning, true),
        ];
        for (name, color, progress, badge, dimmed) in cases {
            let (px, w, h) = super::draw(color, progress, badge, dimmed);
            image::save_buffer(format!("{dir}/{name}.png"), &px, w, h, image::ColorType::Rgba8).unwrap();
        }
    }
}
