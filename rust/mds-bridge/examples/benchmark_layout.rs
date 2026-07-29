use std::time::Instant;

fn main() {
    let path = std::env::args().nth(1).expect("configuration path");
    let shot = std::env::args().nth(2).expect("shot");
    let mode = std::env::args()
        .nth(3)
        .as_deref()
        .unwrap_or("0")
        .parse()
        .expect("mode");
    let mut config = mds_bridge::api::parse_environment(path);
    for column in &mut config.columns {
        for panel in column {
            panel.shot.clone_from(&shot);
            for signal in &mut panel.signal_specs {
                signal.shot.clone_from(&shot);
                signal.read_mode = mode;
            }
        }
    }
    let input = serde_json::to_string(&config).unwrap();
    for run in 1..=2 {
        let fetch_started = Instant::now();
        let results = mds_bridge::api::fetch_signals(input.clone(), mode);
        let fetch_elapsed = fetch_started.elapsed();
        let encode_started = Instant::now();
        let encoded = serde_json::to_string(&results).unwrap();
        let encode_elapsed = encode_started.elapsed();
        let samples: usize = results
            .iter()
            .map(|result| result.series.points.len() + result.series.uniform_y.len())
            .sum();
        println!(
            "run={run} fetch={fetch_elapsed:?} encode={encode_elapsed:?} \
             signals={} samples={samples} json_bytes={}",
            results.len(),
            encoded.len()
        );
    }
}
