# Dry years in Switzerland: river flow and run-of-river hydropower (2003, 2018)
# Anas Meer Ahmed, November 2026
#
# Data:
#   CAMELS-CH (Hoege et al., 2023), https://doi.org/10.5281/zenodo.15025258
#     unzip camels_ch.zip into data/raw/camels_ch/
#   SFOE monthly electricity balance (ogd35), downloaded below

library(tidyverse)
library(janitor)
library(here)

base <- here("data", "raw", "camels_ch", "camels_ch")
obs  <- file.path(base, "timeseries", "observation_based")
st   <- file.path(base, "static_attributes")
dir.create(here("data", "clean"), showWarnings = FALSE, recursive = TRUE)
dir.create(here("output"), showWarnings = FALSE)


# 1. Data quality: which stations have a complete discharge record? ----------

files <- list.files(obs, full.names = TRUE)

station_summary <- map_dfr(files, function(f) {
  x <- read_csv(f, show_col_types = FALSE) |> clean_names()
  tibble(
    gauge_id    = as.numeric(str_extract(basename(f), "\\d+")),
    n_days      = nrow(x),
    n_discharge = sum(!is.na(x$discharge_vol_m3_s))
  )
})


# 2. Catchment attributes and station selection --------------------------------

# Attribute files start with a comment line and use latin1 encoding
read_attr <- function(file) {
  read_csv(file.path(st, file), comment = "#",
           locale = locale(encoding = "latin1"), show_col_types = FALSE) |>
    clean_names()
}

topo  <- read_attr("CAMELS_CH_topographic_attributes.csv")
human <- read_attr("CAMELS_CH_humaninfluence_attributes.csv")
glac  <- read_attr("CAMELS_CH_glacier_attributes.csv")

# Swiss river gauges (no lakes) with no missing days
cand <- station_summary |>
  left_join(topo,  by = "gauge_id") |>
  left_join(human, by = "gauge_id") |>
  left_join(glac,  by = "gauge_id") |>
  filter(country == "CH", water_body_type == "stream", n_discharge == n_days)

write_csv(cand, here("data", "clean", "candidate_stations.csv"))

# Six catchments with no hydropower plants or reservoirs listed,
# from glacier-fed to lowland rain-fed
chosen <- c(2200, 2185, 2070, 2125, 2132, 2034)
order  <- c("Weisse Lütschine", "Plessur", "Emme", "Lorze", "Töss", "Broye")


# 3. Monthly discharge as % of normal -------------------------------------------

q <- map_dfr(chosen, function(id) {
  read_csv(file.path(obs, paste0("CAMELS_CH_obs_based_", id, ".csv")),
           show_col_types = FALSE) |>
    clean_names() |>
    transmute(date, gauge_id = id, discharge = discharge_vol_m3_s)
}) |>
  left_join(cand |> select(gauge_id, water_body_name), by = "gauge_id") |>
  mutate(river = factor(str_replace_all(water_body_name, "_", " "), levels = order),
         year = year(date), month = month(date))

monthly <- q |>
  group_by(river, year, month) |>
  summarise(q_month = mean(discharge), .groups = "drop")

# Normal = 1981-2020 mean for each month, without the dry years themselves
normal <- monthly |>
  filter(!year %in% c(2003, 2018)) |>
  group_by(river, month) |>
  summarise(q_normal = mean(q_month), .groups = "drop")

dry <- monthly |>
  filter(year %in% c(2003, 2018)) |>
  left_join(normal, by = c("river", "month")) |>
  mutate(pct_of_normal = round(100 * q_month / q_normal), year = factor(year))

dry |>
  select(river, year, month, pct_of_normal) |>
  pivot_wider(names_from = month, values_from = pct_of_normal) |>
  print(n = 12)


# 4. Run-of-river hydropower as % of normal --------------------------------------

el_file <- here("data", "raw", "bfe_electricity_monthly.csv")
if (!file.exists(el_file)) {
  download.file(
    "https://www.bfe-ogd.ch/ogd35/ogd35_schweizerische_elektrizitaetsbilanz_monatswerte.csv",
    destfile = el_file, mode = "wb")
}

el <- read_csv(el_file, na = "NULL", show_col_types = FALSE) |>
  clean_names() |>
  select(year = jahr, month = monat, run_of_river = erzeugung_laufwerk_g_wh)

# Electricity data starts in 2000, so the baseline is 2000-2020
el_normal <- el |>
  filter(year <= 2020, !year %in% c(2003, 2018)) |>
  group_by(month) |>
  summarise(ror_normal = mean(run_of_river))

el_dry <- el |>
  filter(year %in% c(2003, 2018)) |>
  left_join(el_normal, by = "month") |>
  mutate(pct_of_normal = round(100 * run_of_river / ror_normal), year = factor(year))

el_dry |>
  select(year, month, pct_of_normal) |>
  pivot_wider(names_from = month, values_from = pct_of_normal)


# 5. Figures -----------------------------------------------------------------------

style <- theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold"))
greys <- c("2003" = "grey65", "2018" = "grey20")

# Figure 1: river flow
ggplot(dry, aes(month, pct_of_normal, fill = year)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.75) +
  geom_hline(yintercept = 100, linetype = "dashed") +
  facet_wrap(~ river, ncol = 3) +
  scale_fill_manual(values = greys) +
  scale_x_continuous(breaks = 1:12, labels = substr(month.abb, 1, 1)) +
  labs(title = "Monthly river flow in the dry years 2003 and 2018",
       subtitle = "Ordered from glacier-fed (top left) to lowland rain-fed rivers",
       x = NULL, y = "% of normal discharge", fill = NULL,
       caption = "Data: CAMELS-CH. Normal = 1981-2020 mean without 2003 and 2018.") +
  style
ggsave(here("output", "fig1_river_flow.png"), width = 9, height = 5.5, dpi = 300)

# Figure 2: national run-of-river power
ggplot(el_dry, aes(month, pct_of_normal, fill = year)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.75) +
  geom_hline(yintercept = 100, linetype = "dashed") +
  scale_fill_manual(values = greys) +
  scale_x_continuous(breaks = 1:12, labels = month.abb) +
  labs(title = "Swiss run-of-river hydropower in 2003 and 2018",
       x = NULL, y = "% of normal production", fill = NULL,
       caption = "Data: SFOE monthly electricity balance. Normal = 2000-2020 mean without 2003 and 2018.") +
  style
ggsave(here("output", "fig2_run_of_river.png"), width = 8, height = 4.5, dpi = 300)

# Figure 3: 2018 rivers vs national power
comb <- bind_rows(
  dry |> filter(year == "2018", river %in% c("Emme", "Lorze", "Töss", "Broye")) |>
    group_by(month) |> summarise(pct = mean(pct_of_normal)) |>
    mutate(series = "Lowland rivers (mean of 4)"),
  dry |> filter(year == "2018", river == "Weisse Lütschine") |>
    transmute(month, pct = pct_of_normal, series = "Glacier-fed river"),
  el_dry |> filter(year == "2018") |>
    transmute(month, pct = pct_of_normal, series = "National run-of-river power")
)

ggplot(comb, aes(month, pct, linetype = series, shape = series)) +
  geom_hline(yintercept = 100, colour = "grey60") +
  geom_line() + geom_point(size = 2) +
  scale_x_continuous(breaks = 1:12, labels = month.abb) +
  labs(title = "2018: lowland rivers vs national run-of-river power",
       x = NULL, y = "% of normal", linetype = NULL, shape = NULL,
       caption = "Data: CAMELS-CH; SFOE monthly electricity balance.") +
  style
ggsave(here("output", "fig3_2018_comparison.png"), width = 8, height = 4.5, dpi = 300)
