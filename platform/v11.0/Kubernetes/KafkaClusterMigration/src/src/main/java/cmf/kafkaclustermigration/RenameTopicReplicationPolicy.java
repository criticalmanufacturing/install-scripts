/**
 * BASED ON 
 * https://github.com/apache/kafka/blob/trunk/connect/mirror-client/src/main/java/org/apache/kafka/connect/mirror/IdentityReplicationPolicy.java
 */

package cmf.kafkaclustermigration;

import org.apache.kafka.connect.mirror.DefaultReplicationPolicy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;
import java.util.HashMap;
import java.util.regex.Pattern;

/**
 * 
 */
public class RenameTopicReplicationPolicy extends DefaultReplicationPolicy {
    private static final Logger log = LoggerFactory.getLogger(RenameTopicReplicationPolicy.class);
    private static Map<String, String> topicReplacements = new HashMap<>();
    private static String oldSystemName = System.getenv("OLD_SYSTEM_NAME");
    private static String newSystemName = System.getenv("NEW_SYSTEM_NAME");
    public static final String SOURCE_CLUSTER_ALIAS_CONFIG = "source.cluster.alias";

    private String sourceClusterAlias = null;

    public RenameTopicReplicationPolicy() {
        super();

        String newSystemNameLowered = newSystemName.toLowerCase();
        
        topicReplacements.put(String.format("%s_dp_replication_shids", oldSystemName), String.format("%s_dp_replication_shids", newSystemNameLowered));
        topicReplacements.put(String.format("%s_dp_replication_events", oldSystemName), String.format("%s_dp_replication_events", newSystemNameLowered));
        topicReplacements.put(String.format("%s_control_topic", oldSystemName), String.format("%s_control_topic", newSystemNameLowered));
        topicReplacements.put(String.format("%s_dp_replication_events", oldSystemName), String.format("%s_dp_replication_events", newSystemNameLowered));
    }

    @Override
    public void configure(Map<String, ?> props) {
        super.configure(props);
        if (props.containsKey(SOURCE_CLUSTER_ALIAS_CONFIG)) {
            sourceClusterAlias = (String) props.get(SOURCE_CLUSTER_ALIAS_CONFIG);
            log.info("Using source cluster alias `{}`.", sourceClusterAlias);
        }
    }

    /**
     * Unlike {@link DefaultReplicationPolicy}, IdentityReplicationPolicy does not include the source
     * cluster alias in the remote topic name. Instead, topic names are unchanged.
     * <p>
     * In the special case of heartbeats, we defer to {@link DefaultReplicationPolicy#formatRemoteTopic(String, String)}.
     */
    @Override
    public String formatRemoteTopic(String sourceClusterAlias, String topic) {
        if (looksLikeHeartbeat(topic)) {
            return super.formatRemoteTopic(sourceClusterAlias, topic);
        } else {
            String newTopic = topicReplacements.get(topic);
            
            if (newTopic == null) {
                newTopic = topic.replaceFirst("(?i)" + Pattern.quote(oldSystemName) + "_", newSystemName.toLowerCase() + "_");
            }

            return newTopic;    
        }
    }

    /**
     * Unlike {@link DefaultReplicationPolicy}, IdentityReplicationPolicy cannot know the source of
     * a remote topic based on its name alone. If <code>source.cluster.alias</code> is provided,
     * this method will return that.
     * <p>
     * In the special case of heartbeats, we defer to {@link DefaultReplicationPolicy#topicSource(String)}.
     */
    @Override
    public String topicSource(String topic) {
        if (looksLikeHeartbeat(topic)) {
            return super.topicSource(topic);
        } else {
            return sourceClusterAlias;
        }
    }

    /**
     * Since any topic may be a remote topic, this just returns `topic`.
     * <p>
     * In the special case of heartbeats, we defer to {@link DefaultReplicationPolicy#upstreamTopic(String)}.
     */
    @Override
    public String upstreamTopic(String topic) {
        if (looksLikeHeartbeat(topic)) {
            return super.upstreamTopic(topic);
        } else {
            return topic;
        }
    }

    private boolean looksLikeHeartbeat(String topic) {
        return topic != null && topic.endsWith(heartbeatsTopic());
    }
}
