-- Refactor simple_exchange_rate_cron()
--
-- Vấn đề bản cũ:
--   1) HARDCODE service_role key (legacy JWT) ngay trong thân hàm -> một bản sao sống của
--      secret nằm trong DB, và khi tắt legacy keys thì cron chết.
--   2) Luôn ghi success=true bất kể kết quả thật: hàm gọi net.http_post rồi pg_sleep(3) và
--      mark success. Do pg_net chỉ thực sự gửi request SAU KHI transaction commit, hàm
--      không thể biết kết quả trong cùng transaction -> "success" là bịa.
--   3) Tự UPDATE exchange_rate_config (last_successful_fetch, api_failures) trong khi
--      edge function đã tự làm việc đó -> ghi đè bằng dữ liệu không có căn cứ.
--
-- Đã kiểm chứng trên prod: edge function fetch-exchange-rates TỰ cập nhật exchange_rates,
-- TỰ cập nhật exchange_rate_config.last_successful_fetch, và TỰ ghi log với provider thật
-- (vd 'fawazahmed0') kèm response_time_ms thật. Nên nhiệm vụ duy nhất của cron là KÍCH HOẠT.
--
-- Bản mới:
--   - Đọc key từ Vault (secret tên 'service_role_key', chứa key sb_secret_...) thay vì hardcode.
--   - Chỉ gửi request; KHÔNG bịa success, KHÔNG đụng vào exchange_rate_config.
--   - Nếu thiếu Vault secret -> ghi log thất bại thật + RAISE WARNING (lỗi không còn im lặng).
--
-- YÊU CẦU: Vault secret 'service_role_key' phải tồn tại và chứa key sb_secret_...
--   select vault.create_secret('<sb_secret_...>', 'service_role_key', 'Key goi edge function');

CREATE OR REPLACE FUNCTION public.simple_exchange_rate_cron()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_edge_function_url TEXT := 'https://susuoambmzdmcygovkea.supabase.co/functions/v1/fetch-exchange-rates';
    v_key TEXT;
    v_request_id BIGINT;
BEGIN
    -- Lấy key từ Vault thay vì hardcode trong source
    SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role_key'
    LIMIT 1;

    IF v_key IS NULL OR v_key = '' THEN
        INSERT INTO exchange_rate_api_log (api_provider, endpoint_url, success, error_message, created_at)
        VALUES ('cron_job', v_edge_function_url, FALSE,
                'Thieu Vault secret "service_role_key" - khong goi duoc edge function', NOW());
        RAISE WARNING 'simple_exchange_rate_cron: thieu Vault secret "service_role_key"';
        RETURN;
    END IF;

    -- Kích hoạt edge function. Edge function tự ghi exchange_rates, tự cập nhật
    -- exchange_rate_config và tự log kết quả -> ở đây không ghi success giả.
    SELECT net.http_post(
        url := v_edge_function_url,
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_key,
            'apikey', v_key,
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object()
    ) INTO v_request_id;

    RAISE LOG 'simple_exchange_rate_cron: da gui request % toi edge function', v_request_id;
END;
$function$;
